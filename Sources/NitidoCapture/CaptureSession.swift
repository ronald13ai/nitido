import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import QuartzCore
import os

public struct CapturedFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let captureHostTimeNs: UInt64
    public let contentRect: CGRect
    public let scale: CGFloat
    public var pixelWidth: Int { CVPixelBufferGetWidth(pixelBuffer) }
    public var pixelHeight: Int { CVPixelBufferGetHeight(pixelBuffer) }
}

public enum CaptureEvent: Sendable, Equatable {
    case started(pixelWidth: Int, pixelHeight: Int, scale: CGFloat)
    case cancelled
    case stopped
    case failed(String)
}

private let log = Logger(subsystem: "ai.ronar.nitido", category: "capture")

/// Runs async main-actor operations one at a time, in the order they were enqueued.
/// The main actor can re-enter at every `await`; chaining keeps a start, an update and a stop
/// from interleaving on the same SCStream.
@MainActor
final class SerialOperations {
    private var tail: Task<Void, Never>?

    @discardableResult
    func enqueue(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            await operation()
        }
        tail = task
        return task
    }
}

/// Wraps the system content picker and an SCStream. One session, one stream at a time.
@MainActor
public final class CaptureSession: NSObject {
    public let frames: AsyncStream<CapturedFrame>
    public let events: AsyncStream<CaptureEvent>
    private let frameOut: AsyncStream<CapturedFrame>.Continuation
    private let eventOut: AsyncStream<CaptureEvent>.Continuation
    private let output: FrameOutput
    private let queue = DispatchQueue(label: "ai.ronar.nitido.capture", qos: .userInteractive)
    /// The stream being started or running. Set before `startCapture()` is awaited so a stop can find it.
    private var stream: SCStream?
    /// Start, update and stop run through here one at a time.
    private let operations = SerialOperations()
    /// Bumped by `stop()`. A start enqueued under an older value is dropped, and a start already
    /// awaiting `startCapture()` stays silent; the stop queued behind it tears that stream down.
    private var generation: UInt64 = 0
    /// True between `presentPicker` and `stop()`; picker updates that land after a stop are ignored.
    private var acceptsPickerUpdates = false

    public override init() {
        let (f, fc) = AsyncStream<CapturedFrame>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let (e, ec) = AsyncStream<CaptureEvent>.makeStream(bufferingPolicy: .bufferingNewest(8))
        frames = f; frameOut = fc; events = e; eventOut = ec
        output = FrameOutput(continuation: fc)
        super.init()
    }

    /// Shows the system picker. Results arrive through `events` and then `frames`.
    public func presentPicker(excludingWindowIDs: [CGWindowID]) {
        let picker = SCContentSharingPicker.shared
        var config = SCContentSharingPickerConfiguration()
        config.allowedPickerModes = [.singleWindow, .singleDisplay]
        config.excludedWindowIDs = excludingWindowIDs.map { Int($0) }
        config.allowsChangingSelectedContent = true
        picker.defaultConfiguration = config
        acceptsPickerUpdates = true
        picker.add(self)
        picker.isActive = true
        picker.present()
    }

    /// Stops capture. Waits for a start that is still in flight and stops that stream too.
    public func stop() async {
        generation &+= 1
        acceptsPickerUpdates = false
        SCContentSharingPicker.shared.isActive = false
        SCContentSharingPicker.shared.remove(self)
        await operations.enqueue { await self.stopStream() }.value
    }

    private func stopStream() async {
        guard let stream else { return }
        self.stream = nil
        do {
            try await stream.stopCapture()
            eventOut.yield(.stopped)
        } catch {
            log.error("stopCapture: \(error.localizedDescription, privacy: .public)")
            eventOut.yield(.failed(error.localizedDescription))
        }
    }

    private func pickerDidUpdate(with filter: SCContentFilter) {
        guard acceptsPickerUpdates else {
            log.info("Ignored a picker update that arrived after stop")
            return
        }
        let enqueuedGeneration = generation
        operations.enqueue { await self.start(with: filter, generation: enqueuedGeneration) }
    }

    private func start(with filter: SCContentFilter, generation enqueuedGeneration: UInt64) async {
        // A stop() arrived after this start was enqueued.
        guard enqueuedGeneration == generation else { return }
        let scale = CGFloat(filter.pointPixelScale)
        let rect = filter.contentRect
        let config = SCStreamConfiguration()
        config.width = Int((rect.width * scale).rounded())
        config.height = Int((rect.height * scale).rounded())
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = true
        config.queueDepth = 3
        config.captureResolution = .best

        if let stream {
            do {
                try await stream.updateContentFilter(filter)
                try await stream.updateConfiguration(config)
                guard enqueuedGeneration == generation else { return }
                eventOut.yield(.started(pixelWidth: config.width, pixelHeight: config.height, scale: scale))
            } catch {
                log.error("updateStream: \(error.localizedDescription, privacy: .public)")
                eventOut.yield(.failed(error.localizedDescription))
            }
            return
        }
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        self.stream = stream
        do {
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
            // A stop() arrived while starting; it runs next and stops this stream.
            guard enqueuedGeneration == generation else { return }
            eventOut.yield(.started(pixelWidth: config.width, pixelHeight: config.height, scale: scale))
        } catch {
            if self.stream === stream { self.stream = nil }
            log.error("startCapture: \(error.localizedDescription, privacy: .public)")
            eventOut.yield(.failed(error.localizedDescription))
        }
    }
}

extension CaptureSession: SCContentSharingPickerObserver {
    nonisolated public func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        // SCContentFilter is not Sendable; the picker hands it over and never touches it again.
        nonisolated(unsafe) let filter = filter
        Task { @MainActor in self.pickerDidUpdate(with: filter) }
    }
    nonisolated public func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in self.eventOut.yield(.cancelled) }
    }
    nonisolated public func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        let message = error.localizedDescription
        log.error("pickerStart: \(message, privacy: .public)")
        Task { @MainActor in self.eventOut.yield(.failed(message)) }
    }
}

extension CaptureSession: SCStreamDelegate {
    nonisolated public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let message = error.localizedDescription
        log.error("streamDidStop: \(message, privacy: .public)")
        // Only compared by identity on the main actor, never used there.
        nonisolated(unsafe) let stopped = stream
        Task { @MainActor in
            // A stream that was already stopped or replaced is only logged; the live one reaches the UI.
            guard self.stream === stopped else { return }
            self.stream = nil
            self.eventOut.yield(.failed(message))
        }
    }
}

/// Mach absolute time, the clock of `SCStreamFrameInfo.displayTime`, in ticks. `CACurrentMediaTime()` and
/// `MTLDrawable.presentedTime` read the same clock in seconds, so a capture time converted here can be subtracted
/// from a presented time to give the capture-to-display latency.
struct MachClock: Sendable {
    let numer: UInt64
    let denom: UInt64

    init() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        numer = UInt64(timebase.numer)
        denom = UInt64(max(timebase.denom, 1))
    }

    func nanoseconds(fromTicks ticks: UInt64) -> UInt64 { ticks * numer / denom }
}

/// Receives sample buffers on the capture queue and yields only complete frames.
private final class FrameOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let continuation: AsyncStream<CapturedFrame>.Continuation
    private let clock = MachClock()
    /// Touched only on the serial capture queue.
    private var reportedMissingDisplayTime = false
    init(continuation: AsyncStream<CapturedFrame>.Continuation) {
        self.continuation = continuation
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let statusRaw = info[.status] as? Int, let status = SCFrameStatus(rawValue: statusRaw), status == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let rect = (info[.contentRect] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } ?? .zero
        let scale = (info[.scaleFactor] as? CGFloat) ?? 1
        // displayTime is mach absolute time (ticks), the same clock CACurrentMediaTime() reads in seconds.
        let hostTimeNs: UInt64
        if let ticks = info[.displayTime] as? UInt64 {
            hostTimeNs = clock.nanoseconds(fromTicks: ticks)
        } else {
            if !reportedMissingDisplayTime {
                reportedMissingDisplayTime = true
                log.error("Frames carry no display time: latency is measured from when each frame reached Nítido, so it leaves out the capture time")
            }
            hostTimeNs = UInt64(CACurrentMediaTime() * 1e9)
        }
        continuation.yield(CapturedFrame(pixelBuffer: pixelBuffer, captureHostTimeNs: hostTimeNs, contentRect: rect, scale: scale))
    }
}
