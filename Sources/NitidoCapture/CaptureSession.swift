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

/// Wraps the system content picker and an SCStream. One session, one stream at a time.
@MainActor
public final class CaptureSession: NSObject {
    public let frames: AsyncStream<CapturedFrame>
    public let events: AsyncStream<CaptureEvent>
    private let frameOut: AsyncStream<CapturedFrame>.Continuation
    private let eventOut: AsyncStream<CaptureEvent>.Continuation
    private let output: FrameOutput
    private let queue = DispatchQueue(label: "ai.ronar.nitido.capture", qos: .userInteractive)
    private var stream: SCStream?

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
        picker.add(self)
        picker.isActive = true
        picker.present()
    }

    public func stop() async {
        SCContentSharingPicker.shared.isActive = false
        SCContentSharingPicker.shared.remove(self)
        guard let stream else { return }
        self.stream = nil
        do { try await stream.stopCapture() } catch { log.error("stopCapture: \(error.localizedDescription)") }
        eventOut.yield(.stopped)
    }

    private func start(with filter: SCContentFilter) async {
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
                eventOut.yield(.started(pixelWidth: config.width, pixelHeight: config.height, scale: scale))
            } catch { eventOut.yield(.failed(error.localizedDescription)) }
            return
        }
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
            self.stream = stream
            eventOut.yield(.started(pixelWidth: config.width, pixelHeight: config.height, scale: scale))
        } catch {
            log.error("startCapture: \(error.localizedDescription)")
            eventOut.yield(.failed(error.localizedDescription))
        }
    }
}

extension CaptureSession: SCContentSharingPickerObserver {
    nonisolated public func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        // SCContentFilter is not Sendable; the picker hands it over and never touches it again.
        nonisolated(unsafe) let filter = filter
        Task { @MainActor in await self.start(with: filter) }
    }
    nonisolated public func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in self.eventOut.yield(.cancelled) }
    }
    nonisolated public func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        Task { @MainActor in self.eventOut.yield(.failed(error.localizedDescription)) }
    }
}

extension CaptureSession: SCStreamDelegate {
    nonisolated public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Task { @MainActor in
            self.stream = nil
            self.eventOut.yield(.failed(error.localizedDescription))
        }
    }
}

/// Receives sample buffers on the capture queue and yields only complete frames.
private final class FrameOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let continuation: AsyncStream<CapturedFrame>.Continuation
    private let timebaseNumer: UInt64
    private let timebaseDenom: UInt64
    init(continuation: AsyncStream<CapturedFrame>.Continuation) {
        self.continuation = continuation
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        timebaseNumer = UInt64(timebase.numer)
        timebaseDenom = UInt64(max(timebase.denom, 1))
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
            hostTimeNs = ticks * timebaseNumer / timebaseDenom
        } else {
            hostTimeNs = UInt64(CACurrentMediaTime() * 1e9)
        }
        continuation.yield(CapturedFrame(pixelBuffer: pixelBuffer, captureHostTimeNs: hostTimeNs, contentRect: rect, scale: scale))
    }
}
