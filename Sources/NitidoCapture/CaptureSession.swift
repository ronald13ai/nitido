import Foundation
import AppKit
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

/// The calls the session makes on a stream once it exists. `SCStream` in the app; a test stands in for it, since an
/// `SCStream` needs a content filter that only the picker (or Screen Recording) hands out.
protocol CaptureStream: AnyObject {
    nonisolated(nonsending) func updateContentFilter(_ contentFilter: SCContentFilter) async throws
    nonisolated(nonsending) func updateConfiguration(_ streamConfig: SCStreamConfiguration) async throws
    nonisolated(nonsending) func stopCapture() async throws
}

extension SCStream: CaptureStream {}

/// The content's pixel size at 1:1 against the size the stream is configured for. ScreenCaptureKit keeps the configured
/// size when the content changes size (a window resized, or moved to a display of another scale; a display whose mode
/// changed): it scales larger content down into it and leaves smaller content in a corner of an otherwise empty frame,
/// so 1:1 is lost. Frames report the content's real size (`observe`, on the capture queue; a display's new mode does
/// too, on the main actor); the first that differs asks the session once (`onChange`), which waits until the size has
/// held for a moment (`settleRemaining`) and takes the newest one (`take`).
final class SizeWatch: @unchecked Sendable {
    struct Size: Equatable, Sendable {
        var width: Int, height: Int, scale: CGFloat
        func samePixels(as other: Size) -> Bool { width == other.width && height == other.height }
    }

    private struct State {
        var configured: Size?
        var latest: Size?
        /// When `latest` last changed (`CACurrentMediaTime`): a live resize changes it every frame.
        var changedAt: Double = 0
        var asked = false
        var onChange: (@Sendable () -> Void)?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func setOnChange(_ onChange: @escaping @Sendable () -> Void) { state.withLock { $0.onChange = onChange } }

    /// The stream runs at `size` now (a start, a pick, a resize); frames compare against it. Nil: stopped.
    func configure(_ size: Size?) {
        state.withLock { $0.configured = size; $0.latest = nil; $0.asked = false }
    }

    /// The content's size at 1:1, from a frame or a display's mode. A size that differs asks the session once.
    func observe(_ size: Size, now: Double = CACurrentMediaTime()) {
        let ask = state.withLock { s -> (@Sendable () -> Void)? in
            guard let configured = s.configured else { return nil }
            if s.latest != size { s.latest = size; s.changedAt = now }
            guard !size.samePixels(as: configured), !s.asked else { return nil }
            s.asked = true
            return s.onChange
        }
        ask?()
    }

    /// Seconds until the newest size has held for `settle`; 0 once it has.
    func settleRemaining(_ settle: Double, now: Double = CACurrentMediaTime()) -> Double {
        state.withLock { max(0, settle - (now - $0.changedAt)) }
    }

    /// The newest size if it differs from the configured one, which it becomes at once (frames already at it then
    /// match); nil when the content is back at the configured size. Either way the next difference asks again.
    func take() -> Size? {
        state.withLock { s in
            s.asked = false
            guard let latest = s.latest, let configured = s.configured, !latest.samePixels(as: configured) else { return nil }
            s.configured = latest
            return latest
        }
    }

    /// The pixel size a frame's content has at 1:1. `contentRect` is in points of the output surface, where
    /// ScreenCaptureKit scaled the content by `contentScale` to fit; `scaleFactor` is the display's pixels per point.
    static func nativeSize(contentRect: CGRect, contentScale: CGFloat, scaleFactor: CGFloat) -> Size? {
        guard contentRect.width > 0, contentRect.height > 0, contentScale > 0, scaleFactor > 0,
              contentRect.width.isFinite, contentRect.height.isFinite, contentScale.isFinite, scaleFactor.isFinite else { return nil }
        let width = (contentRect.width / contentScale * scaleFactor).rounded()
        let height = (contentRect.height / contentScale * scaleFactor).rounded()
        guard width <= 32_768, height <= 32_768 else { return nil }
        return Size(width: Int(width), height: Int(height), scale: scaleFactor)
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
    private var stream: (any CaptureStream)?
    /// The content's size against the configured one; a difference restarts the stream at the new size (`resize`).
    private let sizes = SizeWatch()
    /// How long a new content size must hold before the stream restarts at it, so a live resize, which changes the
    /// size every frame, restarts it once when it stops rather than a burst of times. Internal so a test can shorten it.
    var settle: Double = 0.15
    /// The display a display share captures, for its mode (`screensChanged`); nil for a window share.
    private var sharedDisplay: CGDirectDisplayID?
    /// Watches for display reconfiguration while a stream runs.
    private var screenObserver: (any NSObjectProtocol)?
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
        output = FrameOutput(continuation: fc, sizes: sizes)
        super.init()
        sizes.setOnChange { [weak self] in Task { @MainActor in self?.sizeChanged() } }
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
        sizes.configure(nil); sharedDisplay = nil; stopWatchingScreens()
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

    /// 60 fps BGRA at `width` × `height` pixels, the cursor shown, best resolution.
    private static func configuration(width: Int, height: Int) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = true
        config.queueDepth = 3
        config.captureResolution = .best
        return config
    }

    private func start(with picked: SCContentFilter, generation enqueuedGeneration: UInt64) async {
        // A stop() arrived after this start was enqueued.
        guard enqueuedGeneration == generation else { return }
        // A display pick is captured without Nítido's own windows (`withoutNitido`); a window pick is that window.
        let filter: SCContentFilter, display: CGDirectDisplayID?
        if picked.style == .display {
            do {
                (filter, display) = try await withoutNitido(picked)
            } catch {
                // The pick itself can still be captured (if it cannot, `startCapture` fails and says why): share it as
                // picked, Nítido's windows included, rather than refuse it.
                log.error("Could not list the shareable content to leave Nítido out of the shared display: \(error.localizedDescription, privacy: .public)")
                (filter, display) = (picked, nil)
            }
            guard enqueuedGeneration == generation else { return }
        } else {
            (filter, display) = (picked, nil)
        }
        let scale = CGFloat(filter.pointPixelScale)
        let rect = filter.contentRect
        let size = SizeWatch.Size(width: Int((rect.width * scale).rounded()), height: Int((rect.height * scale).rounded()), scale: scale)
        let config = Self.configuration(width: size.width, height: size.height)

        if let stream {
            do {
                try await stream.updateContentFilter(filter)
                try await stream.updateConfiguration(config)
                guard enqueuedGeneration == generation else { return }
                sizes.configure(size); sharedDisplay = display
                eventOut.yield(.started(pixelWidth: config.width, pixelHeight: config.height, scale: scale))
            } catch {
                log.error("updateStream: \(error.localizedDescription, privacy: .public)")
                eventOut.yield(.failed(error.localizedDescription))
            }
            return
        }
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        self.stream = stream
        // Before the first frame, so it compares against this size.
        sizes.configure(size); sharedDisplay = display
        do {
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
            // A stop() arrived while starting; it runs next and stops this stream.
            guard enqueuedGeneration == generation else { return }
            watchScreens()
            eventOut.yield(.started(pixelWidth: config.width, pixelHeight: config.height, scale: scale))
        } catch {
            if self.stream === stream { self.stream = nil; sizes.configure(nil); sharedDisplay = nil }
            log.error("startCapture: \(error.localizedDescription, privacy: .public)")
            eventOut.yield(.failed(error.localizedDescription))
        }
    }

    /// The picked display, captured without Nítido. The picker only keeps Nítido's windows out of its choices
    /// (`excludedWindowIDs`); a display pick would capture the Share window inside itself, a mirror tunnel. Excluding
    /// the application leaves out every window it has or opens later (the Stop sharing? sheet included).
    private func withoutNitido(_ picked: SCContentFilter) async throws -> (SCContentFilter, CGDirectDisplayID?) {
        let content = try await Self.shareableContent().value
        let match: SCDisplay?
        if #available(macOS 15.2, *), let pickedDisplay = picked.includedDisplays.first {
            match = content.displays.first { $0.displayID == pickedDisplay.displayID }
        } else {
            match = Self.matchingDisplay(frames: content.displays.map(\.frame), contentRect: picked.contentRect).map { content.displays[$0] }
        }
        guard let display = match else {
            // Shared as picked, which may show Nítido's own windows; said in the log rather than refusing the share.
            log.error("No display matches the pick (\(String(describing: picked.contentRect), privacy: .public)); sharing it as picked, Nítido's windows included")
            return (picked, nil)
        }
        let own = getpid()
        if let app = content.applications.first(where: { $0.processID == own }) {
            return (SCContentFilter(display: display, excludingApplications: [app], exceptingWindows: []), display.displayID)
        }
        // Not listed as an application (no window on screen yet): leave out whatever windows it has.
        let windows = content.windows.filter { $0.owningApplication?.processID == own }
        return (SCContentFilter(display: display, excludingWindows: windows), display.displayID)
    }

    /// SCShareableContent is not Sendable; it is made here and only read on the main actor afterwards.
    private struct Handed<Value>: @unchecked Sendable { let value: Value }

    nonisolated private static func shareableContent() async throws -> Handed<SCShareableContent> {
        Handed(value: try await SCShareableContent.current)
    }

    /// The display whose frame is the picked content's rectangle (both in global points), or the only one of that size.
    nonisolated static func matchingDisplay(frames: [CGRect], contentRect: CGRect) -> Int? {
        if let exact = frames.firstIndex(where: { $0.equalTo(contentRect) }) { return exact }
        let sameSize = frames.indices.filter { frames[$0].size.equalTo(contentRect.size) }
        return sameSize.count == 1 ? sameSize[0] : nil
    }

    // MARK: Size changes

    /// A frame (or the display's mode) no longer matches the configured size. Waits until the new size has held for
    /// `settle`, then restarts the stream at the newest one, in turn with starts and stops.
    private func sizeChanged() {
        let enqueuedGeneration = generation
        Task { [weak self] in
            while let wait = self?.sizes.settleRemaining(self?.settle ?? 0), wait > 0 {
                do { try await Task.sleep(for: .seconds(wait)) } catch { return }
            }
            self?.operations.enqueue { [weak self] in await self?.resize(generation: enqueuedGeneration) }
        }
    }

    /// Spec 4 and 12: a new content size restarts the stream at it, and `.started` says the new size and scale, so the
    /// share makes its encoder again (a new `videoConfig` and a keyframe) and tells the viewer.
    private func resize(generation enqueuedGeneration: UInt64) async {
        guard enqueuedGeneration == generation, let stream, let size = sizes.take() else { return }
        log.info("The shared content is now \(size.width, privacy: .public)×\(size.height, privacy: .public) @\(size.scale, privacy: .public)x; restarting the stream at that size")
        do {
            try await stream.updateConfiguration(Self.configuration(width: size.width, height: size.height))
        } catch {
            log.error("updateConfiguration: \(error.localizedDescription, privacy: .public)")
            eventOut.yield(.failed(error.localizedDescription))
            return
        }
        guard enqueuedGeneration == generation else { return }
        eventOut.yield(.started(pixelWidth: size.width, pixelHeight: size.height, scale: size.scale))
    }

    private func watchScreens() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    private func stopWatchingScreens() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
    }

    /// A display was reconfigured. A display share takes its display's new mode as the content's size; a window share
    /// learns its size from its next frame.
    private func screensChanged() {
        guard let display = sharedDisplay else { return }
        guard let mode = CGDisplayCopyDisplayMode(display), mode.width > 0 else {
            log.error("The shared display \(display, privacy: .public) has no mode after a reconfiguration")
            return
        }
        sizes.observe(SizeWatch.Size(width: mode.pixelWidth, height: mode.pixelHeight,
                                     scale: CGFloat(mode.pixelWidth) / CGFloat(mode.width)))
    }

    // MARK: Test seams

    /// Test only: a running stream at `width` × `height`, as a start leaves it, without the picker.
    func runForTesting(_ stream: any CaptureStream, width: Int, height: Int, scale: CGFloat, display: CGDirectDisplayID? = nil) {
        self.stream = stream
        sizes.configure(SizeWatch.Size(width: width, height: height, scale: scale))
        sharedDisplay = display
        watchScreens()
    }

    /// Test only: a frame's content rectangle, scale and display scale, as `FrameOutput` reads them.
    func observeFrameForTesting(contentRect: CGRect, contentScale: CGFloat, scaleFactor: CGFloat) {
        output.observeSize(contentRect: contentRect, contentScale: contentScale, scaleFactor: scaleFactor)
    }
}

extension CaptureSession: SCContentSharingPickerObserver {
    nonisolated public func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        // SCContentFilter is not Sendable; the picker hands it over and never touches it again.
        nonisolated(unsafe) let filter = filter
        Task { @MainActor in self.pickerDidUpdate(with: filter) }
    }
    nonisolated public func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        // With a running stream this was the system's "change shared content" picker (`allowsChangingSelectedContent`):
        // cancelling it keeps the current content. Only the first pick's cancel is `.cancelled`.
        let forRunningStream = stream != nil
        Task { @MainActor in
            if forRunningStream || self.stream != nil {
                log.info("Picker cancelled while capturing; keeping the current content")
                return
            }
            self.eventOut.yield(.cancelled)
        }
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
            self.stream = nil; self.sizes.configure(nil); self.sharedDisplay = nil; self.stopWatchingScreens()
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
    private let sizes: SizeWatch
    /// Touched only on the serial capture queue.
    private var reportedMissingDisplayTime = false
    init(continuation: AsyncStream<CapturedFrame>.Continuation, sizes: SizeWatch) {
        self.continuation = continuation
        self.sizes = sizes
    }

    /// Compares the frame's content, at 1:1, with the size the stream is configured for (`SizeWatch`).
    func observeSize(contentRect: CGRect, contentScale: CGFloat, scaleFactor: CGFloat) {
        guard let size = SizeWatch.nativeSize(contentRect: contentRect, contentScale: contentScale, scaleFactor: scaleFactor) else { return }
        sizes.observe(size)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let statusRaw = info[.status] as? Int, let status = SCFrameStatus(rawValue: statusRaw), status == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let rect = (info[.contentRect] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } ?? .zero
        let scale = (info[.scaleFactor] as? CGFloat) ?? 1
        observeSize(contentRect: rect, contentScale: (info[.contentScale] as? CGFloat) ?? 1, scaleFactor: scale)
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
