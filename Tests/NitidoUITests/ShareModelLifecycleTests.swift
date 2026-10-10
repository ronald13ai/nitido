import XCTest
import CoreVideo
import QuartzCore
import CoreText
import CoreImage
import OSLog
import NitidoTestSupport
@testable import NitidoCapture
@testable import NitidoCodec
@testable import NitidoUI

/// A main-actor latch the test opens by hand, so a stop can be held suspended mid-await.
@MainActor
private final class Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

@MainActor
private final class Journal {
    var lines: [String] = []
}

/// Stands in for CaptureSession: records picker and stop calls, emits events and frames on demand.
@MainActor
private final class FakeSource: CaptureSource {
    let id: String
    let frames: AsyncStream<CapturedFrame>
    let events: AsyncStream<CaptureEvent>
    private let eventOut: AsyncStream<CaptureEvent>.Continuation
    private let frameOut: AsyncStream<CapturedFrame>.Continuation
    private let journal: Journal
    private let stopGate: Gate?

    init(id: String, journal: Journal, stopGate: Gate? = nil) {
        self.id = id
        self.journal = journal
        self.stopGate = stopGate
        (frames, frameOut) = AsyncStream<CapturedFrame>.makeStream()
        (events, eventOut) = AsyncStream<CaptureEvent>.makeStream()
    }

    func presentPicker(excludingWindowIDs: [CGWindowID]) { journal.lines.append("present \(id)") }

    func stop() async {
        journal.lines.append("stop \(id)")
        await stopGate?.wait()
        journal.lines.append("stopped \(id)")
    }

    func emit(_ event: CaptureEvent) { eventOut.yield(event) }

    func emit(frame: CapturedFrame) { frameOut.yield(frame) }

    /// Frames the stream let go before the share took them, handed to the share once (`takeDroppedFrames`).
    var droppedFrames = 0
    func takeDroppedFrames() -> Int { defer { droppedFrames = 0 }; return droppedFrames }
}

/// A captured frame stamped now, in a BGRA buffer the hardware encoder takes (IOSurface backed), with a pattern
/// that changes with `index` so every frame encodes to real data.
private func capturedFrame(index: Int, width: Int = 320, height: Int = 180) throws -> CapturedFrame {
    var buffer: CVPixelBuffer?
    let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
    let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer)
    guard status == kCVReturnSuccess, let buffer else { throw XCTSkip("CVPixelBufferCreate failed: \(status)") }
    CVPixelBufferLockBaseAddress(buffer, [])
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    for y in 0..<height {
        for x in 0..<width {
            let on = (x + y + index * 7) % 32 < 16
            let p = base + y * stride + x * 4
            p[0] = on ? 0x6a : 0x0c; p[1] = on ? 0xa8 : 0x09; p[2] = on ? 0xc9 : 0x08; p[3] = 0xff
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return CapturedFrame(pixelBuffer: buffer, captureHostTimeNs: UInt64(CACurrentMediaTime() * 1e9),
                         contentRect: CGRect(x: 0, y: 0, width: width / 2, height: height / 2), scale: 2)
}

/// A still window of small text, black on white, like the TextEdit window of the hand check: a low quality smears
/// it, a high one keeps it close. Stamped now, like `capturedFrame`.
private func textFrame(width: Int = 1280, height: Int = 720) throws -> CapturedFrame {
    var buffer: CVPixelBuffer?
    let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
    let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer)
    guard status == kCVReturnSuccess, let buffer else { throw XCTSkip("CVPixelBufferCreate failed: \(status)") }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { throw XCTSkip("CGContext over the pixel buffer failed") }
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let font = CTFontCreateWithName("Helvetica" as CFString, 11, nil)
    var line = 0
    for y in stride(from: 8, to: height, by: 13) {
        let text = "Line \(line): The quick brown fox jumps over the lazy dog 0123456789, sphinx of black quartz judge my vow"
        let string = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        context.textPosition = CGPoint(x: 6, y: y)
        CTLineDraw(CTLineCreateWithAttributedString(string), context)
        line += 1
    }
    return CapturedFrame(pixelBuffer: buffer, captureHostTimeNs: UInt64(CACurrentMediaTime() * 1e9),
                         contentRect: CGRect(x: 0, y: 0, width: width / 2, height: height / 2), scale: 2)
}

/// A solid grey frame (`index` sets the shade) stamped now: quick to make at any size, in an IOSurface-backed BGRA
/// buffer the hardware encoder takes.
private func solidFrame(index: Int, width: Int, height: Int) throws -> CapturedFrame {
    var buffer: CVPixelBuffer?
    let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
    let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer)
    guard status == kCVReturnSuccess, let buffer else { throw XCTSkip("CVPixelBufferCreate failed: \(status)") }
    CVPixelBufferLockBaseAddress(buffer, [])
    memset(CVPixelBufferGetBaseAddress(buffer), Int32(0x20 + index * 0x30), CVPixelBufferGetBytesPerRow(buffer) * height)
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return CapturedFrame(pixelBuffer: buffer, captureHostTimeNs: UInt64(CACurrentMediaTime() * 1e9),
                         contentRect: CGRect(x: 0, y: 0, width: width / 2, height: height / 2), scale: 2)
}

/// Mean absolute difference per colour channel between two pictures of the same size as the view draws them (0...255):
/// a decoded one is 4:2:0 YCbCr, a captured one BGRA, and both are drawn into 8-bit sRGB first (`VideoView.image(of:)`).
private func meanError(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Double {
    let width = min(CVPixelBufferGetWidth(a), CVPixelBufferGetWidth(b))
    let height = min(CVPixelBufferGetHeight(a), CVPixelBufferGetHeight(b))
    let context = CIContext(options: [.workingColorSpace: VideoView.colorSpace])
    func drawn(_ buffer: CVPixelBuffer) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        context.render(VideoView.image(of: buffer), toBitmap: &pixels, rowBytes: width * 4,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .BGRA8, colorSpace: VideoView.colorSpace)
        return pixels
    }
    let pa = drawn(a), pb = drawn(b)
    var total = 0
    for i in 0..<(width * height) {
        for c in 0..<3 { total += abs(Int(pa[i * 4 + c]) - Int(pb[i * 4 + c])) }
    }
    return Double(total) / Double(width * height * 3)
}

/// Counts the frames the model hands to the view: a view outside a window reports each one as hidden, and so does a
/// decoded picture a newer one replaced on the way (`FrameSink.dropped`).
@MainActor
private final class PushCounter {
    var count = 0
    init(_ sink: FrameSink) {
        let report = sink.onDropped
        sink.onDropped = { [unowned self] drop in
            if drop == .hidden { count += 1 }
            report?(drop)
        }
    }
}

/// A keyframe from the hardware encoder, so a test can give the model a decoder that works.
@MainActor
private func realKeyframe() async throws -> EncodedFrame {
    let encoder = try VideoEncoder(width: 320, height: 180, preferred: .hevc, bitsPerSecond: 2_000_000)
    defer { encoder.invalidate() }
    let (frames, out) = AsyncStream<EncodedFrame>.makeStream()
    encoder.onFrame = { out.yield($0) }
    Task { try? await Task.sleep(for: .seconds(5)); out.finish() }
    XCTAssertTrue(encoder.encode(try capturedFrame(index: 0).pixelBuffer, captureHostTimeNs: 0))
    for await frame in frames where frame.isKey { return frame }
    throw XCTSkip("the hardware encoder emitted no keyframe within 5 s")
}

/// `count` frames from the hardware encoder, in order: a keyframe, then deltas, each stamped with its index.
@MainActor
private func realFrames(_ count: Int) async throws -> [EncodedFrame] {
    let encoder = try VideoEncoder(width: 320, height: 180, preferred: .hevc, bitsPerSecond: 2_000_000)
    defer { encoder.invalidate() }
    let (frames, out) = AsyncStream<EncodedFrame>.makeStream()
    encoder.onFrame = { out.yield($0) }
    Task { try? await Task.sleep(for: .seconds(10)); out.finish() }
    var next = frames.makeAsyncIterator()
    var encoded: [EncodedFrame] = []
    for index in 0..<count {
        XCTAssertTrue(encoder.encode(try capturedFrame(index: index).pixelBuffer, captureHostTimeNs: UInt64(index)))
        guard let frame = await next.next() else { throw XCTSkip("the hardware encoder emitted no frame within 10 s") }
        encoded.append(frame)
    }
    return encoded
}

/// The capture times of the frames an encoder emitted, once a test has taken its outputs over.
@MainActor
private final class EncodedTimes {
    var times: [UInt64] = []
}

@MainActor
private final class WeakBox {
    weak var value: AnyObject?
    init(_ value: AnyObject) { self.value = value }
}

/// Builds sources named prefix0, prefix1, ... and keeps weak references to check they are released.
@MainActor
private final class Factory {
    let journal: Journal
    let prefix: String
    var gates: [Int: Gate] = [:]
    private(set) var made: [FakeSource] = []
    private(set) var weakMade: [WeakBox] = []
    init(journal: Journal, prefix: String) { self.journal = journal; self.prefix = prefix }

    func make() -> any CaptureSource {
        let index = weakMade.count
        let source = FakeSource(id: "\(prefix)\(index)", journal: journal, stopGate: gates[index])
        made.append(source)
        weakMade.append(WeakBox(source))
        return source
    }

    /// Drops the strong references the factory keeps, so only the model can still hold a source.
    func forget() { made = [] }
    var liveCount: Int { weakMade.filter { $0.value != nil }.count }
}

private struct TimedOut: Error {}

final class ShareModelLifecycleTests: XCTestCase {
    @MainActor
    private func drain() async {
        for _ in 0..<50 { await Task.yield() }
    }

    /// Polls every 5 ms, so a test can wait for each of several quick steps (a decode on the decoder's queue) in turn.
    @MainActor
    private func waitUntil(_ what: String, timeout: Double = 5, _ condition: () -> Bool) async throws {
        let deadline = CACurrentMediaTime() + timeout
        while !condition() {
            guard CACurrentMediaTime() < deadline else { XCTFail("timed out waiting until \(what)"); throw TimedOut() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Share twice while the picker is up: one session, one picker.
    @MainActor
    func testStartWhilePickingDoesNotCreateASecondSession() async {
        let journal = Journal()
        let factory = Factory(journal: journal, prefix: "a")
        let model = ShareModel(makeSource: factory.make)
        model.start(excludingWindowIDs: [])
        await drain()
        model.start(excludingWindowIDs: [])
        await drain()
        XCTAssertEqual(journal.lines, ["present a0"])
        XCTAssertEqual(model.state, .picking)
        await model.stop()
        XCTAssertEqual(journal.lines, ["present a0", "stop a0", "stopped a0"])
    }

    /// Share, cancel, Share again, Stop: the old session is stopped before the new picker, and nothing survives Stop.
    @MainActor
    func testStartAfterCancelRetiresTheOldSessionFirstAndStopLeavesNothingAlive() async {
        let journal = Journal()
        let factory = Factory(journal: journal, prefix: "b")
        var model: ShareModel? = ShareModel(makeSource: factory.make)
        weak let weakModel = model
        model?.start(excludingWindowIDs: [])
        await drain()
        factory.made[0].emit(.cancelled)
        await drain()
        XCTAssertEqual(model?.state, .idle)

        model?.start(excludingWindowIDs: [])
        await drain()
        XCTAssertEqual(journal.lines, ["present b0", "stop b0", "stopped b0", "present b1"])
        XCTAssertEqual(model?.state, .picking)

        await model?.stop()
        XCTAssertEqual(journal.lines.suffix(2), ["stop b1", "stopped b1"])
        XCTAssertEqual(model?.state, .idle)

        factory.forget()
        model = nil
        await drain()
        XCTAssertEqual(factory.liveCount, 0, "a capture session outlived Stop")
        XCTAssertNil(weakModel, "the model outlived Stop")
    }

    /// Cancelling the picker tells the app (`onCancelled`), which goes back to Welcome instead of leaving an empty
    /// Share screen; only the picker's cancel does, a failure does not.
    @MainActor
    func testACancelledPickerCallsOnCancelledOnce() async {
        let journal = Journal()
        let factory = Factory(journal: journal, prefix: "k")
        let model = ShareModel(makeSource: factory.make, screenRecordingGranted: { true })
        var cancels = 0
        model.onCancelled = { cancels += 1 }
        model.start(excludingWindowIDs: [])
        await drain()
        factory.made[0].emit(.failed("the stream stopped"))
        await drain()
        XCTAssertEqual(cancels, 0, "a failure is not a cancel")
        model.retry()
        await drain()
        factory.made[1].emit(.cancelled)
        await drain()
        XCTAssertEqual(cancels, 1)
        XCTAssertEqual(model.state, .idle)
        await model.stop()
    }

    /// The system's "change shared content" picker opens over a live share (`allowsChangingSelectedContent`), and
    /// cancelling it keeps the current content: only the first pick's cancel goes back to Welcome (spec 12). A cancel
    /// that arrives while capturing leaves the share capturing and never calls `onCancelled`.
    @MainActor
    func testCancellingTheChangeContentPickerKeepsTheShare() async {
        let journal = Journal()
        let factory = Factory(journal: journal, prefix: "t")
        let model = ShareModel(makeSource: factory.make, screenRecordingGranted: { true })
        var cancels = 0
        model.onCancelled = { cancels += 1 }
        model.start(excludingWindowIDs: [])
        await drain()
        factory.made[0].emit(.started(pixelWidth: 320, pixelHeight: 180, scale: 2))
        await drain()
        XCTAssertEqual(model.state, .capturing)
        factory.made[0].emit(.cancelled)
        await drain()
        XCTAssertEqual(model.state, .capturing, "a cancelled change of content keeps sharing")
        XCTAssertEqual(cancels, 0, "the app stays on the Share screen")
        XCTAssertEqual(journal.lines, ["present t0"], "the session is not stopped")
        await model.stop()
    }

    /// Frames the capture stream let go before the share took them (it keeps only the newest) count in the strip's
    /// dropped figure (spec 10 and 12).
    @MainActor
    func testFramesTheCaptureStreamLetGoCountAsDropped() async throws {
        let journal = Journal()
        let factory = Factory(journal: journal, prefix: "x")
        let model = ShareModel(makeSource: factory.make, screenRecordingGranted: { true })
        model.start(excludingWindowIDs: [])
        await drain()
        let source = factory.made[0]
        source.emit(.started(pixelWidth: 320, pixelHeight: 180, scale: 2))
        await drain()
        source.droppedFrames = 3
        try await waitUntil("the strip counts the frames the stream let go") { model.snapshot.droppedLastSecond >= 3 }
        XCTAssertEqual(source.droppedFrames, 0, "taken once")
        await model.stop()
    }

    /// Spec 12: after Stop Sharing in the menu bar the Share window offers Retry. The system's picker stays up to resume
    /// the share, and cancelling it is not the first pick's cancel: the failure card stays, with its Retry, instead of
    /// going back to Welcome. A pick from the picker after that still resumes the share.
    @MainActor
    func testCancellingThePickerAfterTheCaptureEndedKeepsTheFailure() async {
        let journal = Journal()
        let factory = Factory(journal: journal, prefix: "z")
        let model = ShareModel(makeSource: factory.make, screenRecordingGranted: { true })
        var cancels = 0
        model.onCancelled = { cancels += 1 }
        model.start(excludingWindowIDs: [])
        await drain()
        let source = factory.made[0]
        source.emit(.started(pixelWidth: 320, pixelHeight: 180, scale: 2))
        await drain()
        source.emit(.failed("stopped"))
        await drain()
        XCTAssertEqual(model.state, .failed("The screen capture stopped. Press Retry to share again."))
        source.emit(.cancelled)
        await drain()
        XCTAssertEqual(model.state, .failed("The screen capture stopped. Press Retry to share again."), "the failure card stays, with Retry")
        XCTAssertEqual(cancels, 0, "the app stays on the Share screen")
        source.emit(.started(pixelWidth: 320, pixelHeight: 180, scale: 2))
        await drain()
        XCTAssertEqual(model.state, .capturing, "a pick after the cancel still resumes the share")
        XCTAssertEqual(journal.lines, ["present z0"], "the same session")
        await model.stop()
    }

    /// A model dropped without Stop is still released: its loops do not hold it.
    @MainActor
    func testLoopsDoNotKeepTheModelAlive() async {
        let journal = Journal()
        let factory = Factory(journal: journal, prefix: "c")
        var model: ShareModel? = ShareModel(makeSource: factory.make)
        weak let weakModel = model
        model?.start(excludingWindowIDs: [])
        await drain()
        model = nil
        await drain()
        XCTAssertNil(weakModel)
    }

    /// Retry after a failure stops the failed session and presents the picker with a fresh one.
    @MainActor
    func testRetryAfterFailureStartsAFreshSession() async {
        let journal = Journal()
        let factory = Factory(journal: journal, prefix: "d")
        let model = ShareModel(makeSource: factory.make, screenRecordingGranted: { true })
        model.start(excludingWindowIDs: [7])
        await drain()
        factory.made[0].emit(.failed("The stream stopped."))
        await drain()
        XCTAssertEqual(model.state, .failed("The screen capture stopped. Press Retry to share again."))

        model.retry()
        await drain()
        XCTAssertEqual(model.state, .picking)
        XCTAssertEqual(journal.lines, ["present d0", "stop d0", "stopped d0", "present d1"])
        await model.stop()
    }

    /// Retry does nothing unless the share has failed.
    @MainActor
    func testRetryIsIgnoredWhenNotFailed() async {
        let journal = Journal()
        let factory = Factory(journal: journal, prefix: "e")
        let model = ShareModel(makeSource: factory.make)
        model.start(excludingWindowIDs: [])
        await drain()
        model.retry()
        await drain()
        XCTAssertEqual(journal.lines, ["present e0"])
        await model.stop()
    }

    /// A failure after capture started is not blamed on the Screen Recording permission.
    @MainActor
    func testFailureWhileCapturingDoesNotAskForPermission() async {
        let journal = Journal()
        let factory = Factory(journal: journal, prefix: "f")
        let model = ShareModel(makeSource: factory.make)
        model.start(excludingWindowIDs: [])
        await drain()
        factory.made[0].emit(.started(pixelWidth: 200, pixelHeight: 100, scale: 2))
        await drain()
        XCTAssertEqual(model.state, .capturing)
        factory.made[0].emit(.failed("The stream stopped."))
        await drain()
        XCTAssertEqual(model.state, .failed("The screen capture stopped. Press Retry to share again."))
        XCTAssertFalse(model.failureNeedsPermission)
        await model.stop()
    }

    /// The pairing code and the Codec loop switch show only over a live share: not while picking, and not after a
    /// failure, when the listener is stopped and a viewer told the code would look for a Mac it cannot find.
    @MainActor
    func testTheCodeAndTheLoopSwitchShowOnlyWhileCapturing() async {
        let journal = Journal()
        let factory = Factory(journal: journal, prefix: "v")
        let model = ShareModel(makeSource: factory.make, screenRecordingGranted: { true })
        model.start(excludingWindowIDs: [])
        await drain()
        XCTAssertFalse(model.showsLiveControls, "picking")
        factory.made[0].emit(.started(pixelWidth: 200, pixelHeight: 100, scale: 2))
        await drain()
        XCTAssertTrue(model.showsLiveControls, "capturing")
        factory.made[0].emit(.failed("The stream stopped."))
        await drain()
        XCTAssertFalse(model.showsLiveControls, "failed: the listener is stopped")
        await model.stop()
    }

    /// The quality slider covers the bitrate controller's range, 2 to 60 Mbps (spec 8), so the loop never runs at a rate
    /// below anything the README and the spec describe.
    func testTheQualitySliderCoversTheControllersRange() {
        XCTAssertEqual(ShareModel.qualityRange, 2...60)
    }

    /// Stop while a restart waits for the old session's stop: the new picker never appears.
    @MainActor
    func testStopWhileARestartWaitsDoesNotPresent() async {
        let journal = Journal()
        let factory = Factory(journal: journal, prefix: "g")
        let gate = Gate()
        factory.gates[0] = gate
        let model = ShareModel(makeSource: factory.make)
        model.start(excludingWindowIDs: [])
        await drain()
        factory.made[0].emit(.cancelled)
        await drain()
        model.start(excludingWindowIDs: [])
        await drain()
        XCTAssertEqual(journal.lines, ["present g0", "stop g0"])

        let stopping = Task { await model.stop() }
        await drain()
        gate.open()
        await stopping.value
        await drain()
        XCTAssertEqual(journal.lines, ["present g0", "stop g0", "stopped g0"])
        XCTAssertEqual(model.state, .idle)
    }

    /// A start that lands while the same model's stop is still waiting wins: the stop does not reset it to idle.
    @MainActor
    func testStartDuringStopIsNotClobberedByTheStop() async {
        let journal = Journal()
        let factory = Factory(journal: journal, prefix: "j")
        let gate = Gate()
        factory.gates[0] = gate
        let model = ShareModel(makeSource: factory.make)
        model.start(excludingWindowIDs: [])
        await drain()
        let stopping = Task { await model.stop() }
        await drain()
        model.start(excludingWindowIDs: [])
        await drain()
        XCTAssertEqual(journal.lines, ["present j0", "stop j0"])

        gate.open()
        await stopping.value
        await drain()
        XCTAssertEqual(model.state, .picking)
        XCTAssertEqual(journal.lines, ["present j0", "stop j0", "stopped j0", "present j1"])
        await model.stop()
    }

    /// Without the Screen Recording grant, the picker screen says macOS may ask after the pick (spec 12).
    @MainActor
    func testPickerExplainsScreenRecordingOnlyWhenNotGranted() async {
        let journal = Journal()
        let denied = ShareModel(makeSource: Factory(journal: journal, prefix: "k").make, screenRecordingGranted: { false })
        XCTAssertFalse(denied.mayAskForScreenRecording)
        denied.start(excludingWindowIDs: [])
        XCTAssertEqual(denied.state, .picking)
        XCTAssertTrue(denied.mayAskForScreenRecording)
        await denied.stop()

        let granted = ShareModel(makeSource: Factory(journal: journal, prefix: "l").make, screenRecordingGranted: { true })
        granted.start(excludingWindowIDs: [])
        XCTAssertEqual(granted.state, .picking)
        XCTAssertFalse(granted.mayAskForScreenRecording)
        await granted.stop()
    }

    /// A failure before capture started, without the grant, offers System Settings.
    @MainActor
    func testFailureBeforeCaptureWithoutTheGrantAsksForPermission() async {
        let journal = Journal()
        let factory = Factory(journal: journal, prefix: "m")
        let model = ShareModel(makeSource: factory.make, screenRecordingGranted: { false })
        model.start(excludingWindowIDs: [])
        await drain()
        factory.made[0].emit(.failed("The user declined TCCs for application, window, display capture"))
        await drain()
        XCTAssertTrue(model.failureNeedsPermission)
        XCTAssertEqual(model.state, .failed("Nítido is not allowed to record the screen."), "ScreenCaptureKit's words stay in the log")
        await model.stop()
    }

    /// Spec 9 and 12: a denied Screen Recording (`SCStreamError.userDeclined`) is said in plain words with the fix, even
    /// when the grant check still reads its old answer, and Stop Sharing in the menu bar (`userStopped`) says so. What
    /// ScreenCaptureKit said ("The user declined TCCs for application, window, display capture") goes to the log only.
    @MainActor
    func testCaptureFailuresAreSaidInPlainWords() async {
        let journal = Journal()
        let factory = Factory(journal: journal, prefix: "w")
        let model = ShareModel(makeSource: factory.make, screenRecordingGranted: { true })
        model.start(excludingWindowIDs: [])
        await drain()
        let denial = "The user declined TCCs for application, window, display capture (com.apple.ScreenCaptureKit.SCStreamErrorDomain -3801)"
        factory.made[0].emit(.failed(CaptureFailure(reason: .notPermitted, detail: denial)))
        await drain()
        XCTAssertTrue(model.failureNeedsPermission)
        XCTAssertEqual(model.state, .failed("Nítido is not allowed to record the screen."))

        model.retry()
        await drain()
        factory.made[1].emit(.started(pixelWidth: 320, pixelHeight: 180, scale: 2))
        await drain()
        let stopped = "The user stopped the stream (com.apple.ScreenCaptureKit.SCStreamErrorDomain -3817)"
        factory.made[1].emit(.failed(CaptureFailure(reason: .stoppedFromMenuBar, detail: stopped)))
        await drain()
        XCTAssertFalse(model.failureNeedsPermission)
        XCTAssertEqual(model.state, .failed("Sharing was stopped from the menu bar. Press Retry to share again."))
        guard case .failed(let shown) = model.state else { return XCTFail() }
        XCTAssertFalse(shown.contains("SCStreamErrorDomain"), shown)
        await model.stop()
    }

    /// Codec loop on while capturing: frames go through the hardware encoder and decoder, the decoded frame reaches
    /// the view with the raw frame and the divider to compare against, the strip names the codec and measures it,
    /// turning the loop off shows the raw frame alone, and Stop turns the loop off with the session.
    @MainActor
    func testCodecLoopEncodesDecodesAndComparesUntilTurnedOffOrStopped() async throws {
        let journal = Journal()
        let factory = Factory(journal: journal, prefix: "n")
        let model = ShareModel(makeSource: factory.make, screenRecordingGranted: { true })
        let view = VideoView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        model.sink.view = view
        model.start(excludingWindowIDs: [])
        await drain()
        let source = factory.made[0]
        source.emit(.started(pixelWidth: 320, pixelHeight: 180, scale: 2))
        await drain()
        XCTAssertEqual(model.state, .capturing)
        XCTAssertEqual(model.codecLabel, "raw")

        model.dividerPosition = 0.3
        model.loopback = true
        var raws: [CVPixelBuffer] = []
        for i in 0..<30 {
            let frame = try capturedFrame(index: i)
            raws.append(frame.pixelBuffer)
            source.emit(frame: frame)
            try await Task.sleep(for: .milliseconds(16))
        }
        // The snapshot loop publishes the codec figure every 250 ms.
        var waits = 0
        while model.codecMs == nil, waits < 40 { try await Task.sleep(for: .milliseconds(50)); waits += 1 }
        XCTAssertTrue(["HEVC", "H.264"].contains(model.codecLabel), "codec label \(model.codecLabel)")
        let codecMs = try XCTUnwrap(model.codecMs, "no codec time measured")
        XCTAssertGreaterThan(codecMs, 0)
        XCTAssertGreaterThan(model.snapshot.bitrateMbps, 0, "encoded bytes count in the bitrate")
        XCTAssertNil(model.codecNotice)
        XCTAssertEqual(model.state, .capturing)
        let held = try XCTUnwrap(view.pacer.held)
        let compared = try XCTUnwrap(held.compareWith, "the decoded frame is shown against a raw frame")
        XCTAssertTrue(raws.contains { $0 === compared }, "the comparison is a captured frame")
        XCTAssertFalse(raws.contains { $0 === held.pixelBuffer }, "the main picture is the decoded frame")
        XCTAssertEqual(held.divider, 0.3)

        model.loopback = false
        XCTAssertEqual(model.codecLabel, "raw")
        XCTAssertNil(model.codecMs)
        let plain = try capturedFrame(index: 99)
        source.emit(frame: plain)
        await drain()
        XCTAssertTrue(view.pacer.held?.pixelBuffer === plain.pixelBuffer, "the loop off shows the captured frame")
        XCTAssertNil(view.pacer.held?.compareWith)

        model.loopback = true
        source.emit(frame: try capturedFrame(index: 100))
        await drain()
        XCTAssertNotEqual(model.codecLabel, "raw")
        await model.stop()
        XCTAssertFalse(model.loopback, "Stop turns the codec loop off")
        XCTAssertEqual(model.codecLabel, "raw")
        XCTAssertNil(model.codecMs)
    }

    /// A still source sends no frames (ScreenCaptureKit forwards only changed ones): a divider move still changes the
    /// comparison the view keeps and draws again, and turning the loop off puts the newest raw frame alone in its
    /// place at once, and a decoded frame landing late does not bring the comparison back.
    @MainActor
    func testStillSourceShowsDividerMovesAndTheLoopTurningOffAtOnce() async throws {
        let journal = Journal()
        let factory = Factory(journal: journal, prefix: "o")
        let model = ShareModel(makeSource: factory.make, screenRecordingGranted: { true })
        let view = VideoView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        model.sink.view = view
        model.start(excludingWindowIDs: [])
        await drain()
        let source = factory.made[0]
        source.emit(.started(pixelWidth: 320, pixelHeight: 180, scale: 2))
        await drain()
        model.loopback = true
        var raws: [CVPixelBuffer] = []
        for i in 0..<10 {
            let frame = try capturedFrame(index: i)
            raws.append(frame.pixelBuffer)
            source.emit(frame: frame)
            try await Task.sleep(for: .milliseconds(16))
        }
        // The source goes still: wait for the last decoded frames to land.
        var waits = 0
        while view.pacer.held?.compareWith == nil, waits < 40 { try await Task.sleep(for: .milliseconds(50)); waits += 1 }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(model.state, .capturing)
        let held = try XCTUnwrap(view.pacer.held)
        XCTAssertNotNil(held.compareWith, "a decoded frame is shown against a raw one")
        XCTAssertEqual(held.divider, 0.5)

        model.dividerPosition = 0.8
        XCTAssertEqual(view.pacer.held?.divider, 0.8, "the divider moves without a new frame")
        XCTAssertTrue(view.pacer.held?.pixelBuffer === held.pixelBuffer, "the same decoded frame, split elsewhere")

        model.loopback = false
        XCTAssertTrue(view.pacer.held?.pixelBuffer === raws.last, "the newest raw frame replaces the comparison")
        XCTAssertNil(view.pacer.held?.compareWith)
        try await Task.sleep(for: .milliseconds(200))
        await drain()
        XCTAssertTrue(view.pacer.held?.pixelBuffer === raws.last, "no late decoded frame brings the comparison back")
        XCTAssertNil(view.pacer.held?.compareWith)
        await model.stop()
    }

    /// A still source sends no frame (ScreenCaptureKit forwards only changed ones), so turning the codec loop on
    /// encodes the frame on screen at once: the strip names the codec, measures it and counts its bytes, the decoded
    /// frame is shown against that raw frame (so the divider moves too), stamped when it was encoded again rather
    /// than when the still picture was captured, and not counted as a second capture. Turning the loop off and on
    /// again does the same with the same frame; after Stop, a new share never encodes the old share's frame.
    @MainActor
    func testCodecLoopTurnedOnOverAStillSourceShowsTheComparisonAtOnce() async throws {
        let journal = Journal()
        let factory = Factory(journal: journal, prefix: "q")
        let model = ShareModel(makeSource: factory.make, screenRecordingGranted: { true })
        let view = VideoView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        model.sink.view = view
        model.start(excludingWindowIDs: [])
        await drain()
        let source = factory.made[0]
        source.emit(.started(pixelWidth: 320, pixelHeight: 180, scale: 2))
        await drain()
        let raw = try capturedFrame(index: 0)
        source.emit(frame: raw)
        await drain()
        XCTAssertTrue(view.pacer.held?.pixelBuffer === raw.pixelBuffer, "the raw frame is on screen")
        try await Task.sleep(for: .milliseconds(300))   // the source stays still from here on

        let turnedOnAt = UInt64(CACurrentMediaTime() * 1e9)
        model.loopback = true
        XCTAssertTrue(["HEVC", "H.264"].contains(model.codecLabel), "the encoder is made at once: \(model.codecLabel)")
        var waits = 0
        while view.pacer.held?.compareWith == nil, waits < 40 { try await Task.sleep(for: .milliseconds(50)); waits += 1 }
        let held = try XCTUnwrap(view.pacer.held)
        XCTAssertTrue(held.compareWith === raw.pixelBuffer, "the decoded frame is shown against the still raw frame")
        XCTAssertFalse(held.pixelBuffer === raw.pixelBuffer, "the main picture is the decoded frame")
        XCTAssertGreaterThanOrEqual(held.captureHostTimeNs, turnedOnAt, "stamped when encoded again, not when captured")
        waits = 0
        while model.codecMs == nil, waits < 40 { try await Task.sleep(for: .milliseconds(50)); waits += 1 }
        XCTAssertNotNil(model.codecMs, "the codec time is measured on a still source")
        XCTAssertGreaterThan(model.snapshot.bitrateMbps, 0, "the encoded bytes count in the bitrate")
        XCTAssertLessThanOrEqual(model.snapshot.captureFPS, 1, "the frame encoded again is not a new capture")
        XCTAssertNil(model.codecNotice)
        XCTAssertEqual(model.state, .capturing)

        model.dividerPosition = 0.7
        XCTAssertEqual(view.pacer.held?.divider, 0.7, "the divider moves over the still comparison")

        model.loopback = false
        XCTAssertTrue(view.pacer.held?.pixelBuffer === raw.pixelBuffer, "loop off: the raw frame alone")
        XCTAssertNil(view.pacer.held?.compareWith)
        model.loopback = true
        waits = 0
        while view.pacer.held?.compareWith == nil, waits < 40 { try await Task.sleep(for: .milliseconds(50)); waits += 1 }
        XCTAssertTrue(view.pacer.held?.compareWith === raw.pixelBuffer, "on again: the same still frame, compared")
        XCTAssertFalse(view.pacer.held?.pixelBuffer === raw.pixelBuffer)

        await model.stop()
        model.start(excludingWindowIDs: [])
        await drain()
        factory.made[1].emit(.started(pixelWidth: 320, pixelHeight: 180, scale: 2))
        await drain()
        model.loopback = true
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(model.codecLabel, "raw", "a new share has no frame to encode until its source sends one")
        XCTAssertNil(view.pacer.held, "the old share's frame is not shown again")
        await model.stop()
    }

    /// A quality change over a still source is encoded once the slider rests: the newest raw frame again, as the
    /// keyframe of an encoder made at the new rate, so small text visibly smears at 1 Mbps and sharpens again at 60
    /// (the running encoder's keyframe would keep the old quality). A drag of several steps encodes once.
    @MainActor
    func testQualityChangeOverAStillSourceIsEncodedAgainOnceTheSliderRests() async throws {
        let journal = Journal()
        let factory = Factory(journal: journal, prefix: "r")
        let model = ShareModel(makeSource: factory.make, screenRecordingGranted: { true })
        let view = VideoView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        model.sink.view = view
        model.start(excludingWindowIDs: [])
        await drain()
        let source = factory.made[0]
        source.emit(.started(pixelWidth: 1280, pixelHeight: 720, scale: 2))
        await drain()
        let raw = try textFrame()
        source.emit(frame: raw)
        await drain()
        model.qualityMbps = 60
        model.loopback = true
        var waits = 0
        while view.pacer.held?.compareWith == nil, waits < 40 { try await Task.sleep(for: .milliseconds(50)); waits += 1 }
        let sharp = try XCTUnwrap(view.pacer.held?.pixelBuffer)
        XCTAssertFalse(sharp === raw.pixelBuffer)
        let sharpError = meanError(sharp, raw.pixelBuffer)
        try await Task.sleep(for: .milliseconds(300))

        let pushes = PushCounter(model.sink)
        for quality in [40.0, 20, 8, 3, 1] {   // a slider dragged down
            model.qualityMbps = quality
            await drain()
        }
        XCTAssertEqual(pushes.count, 0, "nothing is encoded while the slider moves")
        waits = 0
        while view.pacer.held?.pixelBuffer === sharp, waits < 40 { try await Task.sleep(for: .milliseconds(50)); waits += 1 }
        let held = try XCTUnwrap(view.pacer.held)
        XCTAssertFalse(held.pixelBuffer === sharp, "the still picture is encoded again at the new quality")
        XCTAssertTrue(held.compareWith === raw.pixelBuffer, "against the same raw frame")
        let softError = meanError(held.pixelBuffer, raw.pixelBuffer)
        XCTAssertGreaterThan(softError, sharpError * 2,
                             "1 Mbps smears the text: error \(softError) against \(sharpError) at 60 Mbps")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(pushes.count, 1, "one encode once the slider rests, not one per step")

        let soft = held.pixelBuffer
        model.qualityMbps = 60   // and back up
        waits = 0
        while view.pacer.held?.pixelBuffer === soft, waits < 40 { try await Task.sleep(for: .milliseconds(50)); waits += 1 }
        let sharpAgain = try XCTUnwrap(view.pacer.held?.pixelBuffer)
        XCTAssertFalse(sharpAgain === soft, "raising the quality encodes the still picture again")
        let sharpAgainError = meanError(sharpAgain, raw.pixelBuffer)
        XCTAssertLessThan(sharpAgainError, softError / 2, "60 Mbps sharpens it: error \(sharpAgainError) against \(softError)")
        XCTAssertEqual(pushes.count, 2)
        XCTAssertNil(model.codecNotice)
        XCTAssertEqual(model.state, .capturing)
        await model.stop()
    }

    /// A decoder that keeps throwing is not a silent freeze while only decoded frames reach the screen: each throw
    /// counts as a dropped frame, nine in a row leave the share running (a fresh keyframe may bring it back), the tenth
    /// fails the share with Retry and stops the loop's codec. A frame decoded in between starts the count again.
    @MainActor
    func testDecoderThatKeepsThrowingFailsTheShareAfterTenInARow() async throws {
        let journal = Journal()
        let factory = Factory(journal: journal, prefix: "p")
        let model = ShareModel(makeSource: factory.make, screenRecordingGranted: { true })
        model.start(excludingWindowIDs: [])
        await drain()
        factory.made[0].emit(.started(pixelWidth: 320, pixelHeight: 180, scale: 2))
        await drain()
        model.loopback = true
        let key = try await realKeyframe()
        // Real parameter sets build a decoder that works; the data is not a picture, so `decode` throws.
        func unreadable(_ seq: UInt32) -> EncodedFrame {
            EncodedFrame(seq: seq, captureHostTimeNs: 1, isKey: true, data: Data([0, 0, 0, 3, 1, 2, 3]),
                         parameterSets: key.parameterSets, codec: key.codec, width: key.width, height: key.height)
        }
        // Decoding runs on the decoder's queue: each failure lands (and lets that decoder go) before the next frame,
        // whose setup then makes a fresh decoder, as the keyframe the loop asks for would.
        func fail(_ seq: UInt32) async throws {
            let before = model.decodeFailures
            model.handleEncoded(unreadable(seq))
            try await waitUntil("frame \(seq) fails") { model.decodeFailures > before || model.state != .capturing }
        }
        for seq in 0..<9 { try await fail(UInt32(seq)) }
        XCTAssertEqual(model.decodeFailures, 9)
        XCTAssertEqual(model.state, .capturing, "nine throws in a row leave the share running")
        model.handleEncoded(key)
        try await waitUntil("the keyframe is decoded") { model.decodeFailures == 0 }
        for seq in 10..<19 { try await fail(UInt32(seq)) }
        XCTAssertEqual(model.state, .capturing, "a frame decoded in between starts the count again")
        try await fail(19)
        XCTAssertEqual(model.state, .failed("Video decoding keeps failing."))
        XCTAssertEqual(model.codecLabel, "raw")
        XCTAssertNil(model.codecMs)
        // The snapshot loop publishes the dropped figure every 250 ms, and one may land between the failures.
        var waits = 0
        while model.snapshot.droppedLastSecond < 19, waits < 20 { try await Task.sleep(for: .milliseconds(50)); waits += 1 }
        XCTAssertGreaterThanOrEqual(model.snapshot.droppedLastSecond, 19, "every throw counts as a dropped frame")
        // The raw picture goes on until Retry, and the stream may report a new size meanwhile (a window resized): the
        // picture takes it, the failure stays.
        factory.made[0].emit(.started(pixelWidth: 640, pixelHeight: 360, scale: 2))
        await drain()
        XCTAssertEqual(model.pixelSize, CGSize(width: 640, height: 360))
        XCTAssertEqual(model.state, .failed("Video decoding keeps failing."), "only Retry ends a failure")
        await model.stop()
    }

    /// Spec 12, "Decode error: request keyframe", for the codec loop: after a decode error lets the loop's decoder go,
    /// every delta that comes before a keyframe asks for one again, so a forced keyframe that never came out (the
    /// encoder failed or dropped it, or a frame took the request first) cannot freeze the loop until the periodic
    /// keyframe, or for good over a still source.
    @MainActor
    func testTheCodecLoopAsksAgainForAKeyframeUntilOneArrives() async throws {
        let journal = Journal()
        let factory = Factory(journal: journal, prefix: "w")
        let model = ShareModel(makeSource: factory.make, screenRecordingGranted: { true })
        let view = VideoView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        model.sink.view = view
        model.start(excludingWindowIDs: [])
        await drain()
        let source = factory.made[0]
        source.emit(.started(pixelWidth: 320, pixelHeight: 180, scale: 2))
        await drain()
        model.loopback = true
        source.emit(frame: try capturedFrame(index: 0))
        try await waitUntil("the loop shows a decoded frame") { view.pacer.held?.compareWith != nil }
        let encoder = try XCTUnwrap(model.encoder)

        // A decode error lets the loop's decoder go and asks the encoder for a keyframe.
        let key = try await realKeyframe()
        model.handleEncoded(EncodedFrame(seq: 50, captureHostTimeNs: 1, isKey: true, data: Data([0, 0, 0, 3, 1, 2, 3]),
                                         parameterSets: key.parameterSets, codec: key.codec, width: key.width, height: key.height))
        try await waitUntil("the decode error lands") { model.decodeFailures == 1 }
        XCTAssertTrue(encoder.isKeyframeRequested)

        // A frame takes the request, and its keyframe never reaches the loop.
        encoder.onFrame = { _ in }
        XCTAssertTrue(encoder.encode(try capturedFrame(index: 1).pixelBuffer, captureHostTimeNs: 2))
        XCTAssertFalse(encoder.isKeyframeRequested, "the frame took the request")

        // The next delta finds no decoder: it asks again.
        model.handleEncoded(EncodedFrame(seq: 51, captureHostTimeNs: 3, isKey: false, data: Data([0, 0, 0, 3, 1, 2, 3]),
                                         parameterSets: [], codec: key.codec, width: key.width, height: key.height))
        XCTAssertTrue(encoder.isKeyframeRequested, "a delta with no decoder to read it asks for a keyframe again")
        XCTAssertEqual(model.state, .capturing)
        await model.stop()
    }

    /// Spec 4, in the codec loop: a decoder that falls behind drops work rather than queue it, and it judges behind by
    /// how long a frame has waited, not by how many wait. Four deltas handed over at once (the decoder's queue held
    /// here, as a stall would) all wait; 60 ms later the oldest has waited past 50 ms, so the next delta starts a skip to
    /// the next keyframe and the one after it is skipped too; the keyframe then drops the four that waited instead of
    /// decoding them first. All six count as dropped, none is a decode failure, and the keyframe reaches the screen.
    /// Spec 12: the skip is logged, once, with what was waiting.
    @MainActor
    func testTheCodecLoopSkipsToTheKeyframeWhenItFallsBehindAndCountsWhatItDropped() async throws {
        let journal = Journal()
        let factory = Factory(journal: journal, prefix: "s")
        let model = ShareModel(makeSource: factory.make, screenRecordingGranted: { true })
        let pushed = PushCounter(model.sink)
        model.start(excludingWindowIDs: [])
        await drain()
        factory.made[0].emit(.started(pixelWidth: 320, pixelHeight: 180, scale: 2))
        await drain()
        model.loopback = true
        let key = try await realKeyframe()
        // Numbered one after another; the deltas are never decoded, so any bytes do.
        func frame(_ seq: UInt32, isKey: Bool) -> EncodedFrame {
            EncodedFrame(seq: seq, captureHostTimeNs: 1, isKey: isKey, data: isKey ? key.data : Data([0, 0, 0, 3, 1, 2, 3]),
                         parameterSets: isKey ? key.parameterSets : [], codec: key.codec, width: key.width, height: key.height)
        }
        model.handleEncoded(frame(0, isKey: true))
        try await waitUntil("the first keyframe reaches the screen") { pushed.count == 1 }
        let decoder = try XCTUnwrap(model.decoder)
        decoder.drainForTesting()
        let mark = LogMark()
        decoder.suspendForTesting()
        for seq in 1...4 { model.handleEncoded(frame(UInt32(seq), isKey: false)) }   // a burst: all four wait
        try await Task.sleep(for: .milliseconds(60))
        for seq in 5...6 { model.handleEncoded(frame(UInt32(seq), isKey: false)) }   // skipped
        model.handleEncoded(frame(7, isKey: true))
        XCTAssertTrue(model.decoder === decoder, "the keyframe's setup is the one the decoder has")
        decoder.resumeForTesting()
        try await waitUntil("the keyframe after the skip reaches the screen") { pushed.count == 2 }
        try await waitUntil("the six frames count as dropped", timeout: 2) { model.snapshot.droppedLastSecond == 6 }
        XCTAssertEqual(model.decodeFailures, 0, "no delta reached the decoder")
        XCTAssertEqual(model.state, .capturing)
        let skips = try mark.entries("share").filter { $0.composedMessage.contains("keyframe") && $0.composedMessage.contains("behind") }
        XCTAssertEqual(skips.count, 1, "one line for the skip: \(skips.map(\.composedMessage))")
        XCTAssertEqual(skips.first?.level, .info)
        let line = try XCTUnwrap(skips.first?.composedMessage)
        let prefix = "the codec loop's decoder fell behind with 4 frames waiting, the oldest for "
        let suffix = " ms; skipping to the next keyframe"
        XCTAssertTrue(line.hasPrefix(prefix) && line.hasSuffix(suffix), line)
        let waited = Double(line.dropFirst(prefix.count).dropLast(suffix.count))
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(waited, "a figure in ms: \(line)"), 60, "the oldest waited through the 60 ms")
        await model.stop()
    }

    /// The codec loop hands its decoded pictures to the main thread as the viewer does: with the main thread held for
    /// half a second while 29 frames decode at 58 fps, the decoder keeps up, and the view, in a window on screen
    /// (`ShowingDisplay`), then gets one picture, the newest, while the 28 decoded before it count as dropped without
    /// reaching it.
    @MainActor
    func testTheCodecLoopWhoseMainThreadStallsShowsOnlyTheNewestDecodedFrame() async throws {
        let journal = Journal()
        let factory = Factory(journal: journal, prefix: "m")
        let model = ShareModel(makeSource: factory.make, screenRecordingGranted: { true })
        let view = VideoView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        let display = ShowingDisplay()
        display.show(view)
        model.sink.view = view
        model.start(excludingWindowIDs: [])
        await drain()
        factory.made[0].emit(.started(pixelWidth: 320, pixelHeight: 180, scale: 2))
        await drain()
        model.loopback = true
        let frames = try await realFrames(30)
        model.handleEncoded(frames[0])
        try await waitUntil("the keyframe reaches the screen") { display.drawn.count == 1 }
        let decoder = try XCTUnwrap(model.decoder)
        decoder.drainForTesting()

        let deltas = frames[1...].map(\.videoFrame)
        let results = feedAtFiftyEightFpsWhileTheCallingThreadStalls(deltas, to: decoder)
        XCTAssertEqual(results, Array(repeating: .queued, count: deltas.count), "the decoder never fell behind")
        try await waitUntil("the newest decoded frame reaches the view") {
            display.drawn.last == frames.last?.captureHostTimeNs
        }
        await drain()
        XCTAssertEqual(display.drawn.count, 2, "one picture after the stall, not one per decoded frame")
        try await waitUntil("the pictures the newest replaced count as dropped", timeout: 2) {
            model.snapshot.droppedLastSecond == deltas.count - 1
        }
        XCTAssertEqual(model.decodeFailures, 0)
        await model.stop()
    }

    /// The same stall with the view outside any window (it cannot show frames: the Share window minimized or covered
    /// is the same): the pictures the newest replaced are a pause, as every picture pushed then is (`.hidden`), not
    /// dropped frames. All 30 reach the view as hidden, and the dropped figure stays at 0.
    @MainActor
    func testLoopPicturesReplacedWhileTheViewCannotShowThemAreAPauseNotDrops() async throws {
        let journal = Journal()
        let factory = Factory(journal: journal, prefix: "h")
        let model = ShareModel(makeSource: factory.make, screenRecordingGranted: { true })
        let hidden = PushCounter(model.sink)
        let view = VideoView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        model.sink.view = view
        model.start(excludingWindowIDs: [])
        await drain()
        factory.made[0].emit(.started(pixelWidth: 320, pixelHeight: 180, scale: 2))
        await drain()
        model.loopback = true
        let frames = try await realFrames(30)
        model.handleEncoded(frames[0])
        try await waitUntil("the keyframe reaches the view") { hidden.count == 1 }
        let decoder = try XCTUnwrap(model.decoder)
        decoder.drainForTesting()

        let deltas = frames[1...].map(\.videoFrame)
        let results = feedAtFiftyEightFpsWhileTheCallingThreadStalls(deltas, to: decoder)
        XCTAssertEqual(results, Array(repeating: .queued, count: deltas.count))
        try await waitUntil("the newest picture and the 28 it replaced reach the view as hidden", timeout: 2) {
            hidden.count == frames.count
        }
        try await Task.sleep(for: .milliseconds(300))   // the 250 ms loop publishes the figures
        XCTAssertEqual(model.snapshot.droppedLastSecond, 0, "a pause, not dropped frames")
        XCTAssertEqual(model.decodeFailures, 0)
        await model.stop()
    }

    /// Spec 9: a codec that cannot start is said in one plain sentence, what happened and what to do, with the status
    /// for whoever reads the log alongside (the log names the case). No hardware encoder takes a picture 100,000 pixels
    /// wide, so the loop's encoder cannot start here, as on a Mac whose encoder is not available.
    @MainActor
    func testAnEncoderThatCannotStartSaysSoInOneSentence() async throws {
        let journal = Journal()
        let factory = Factory(journal: journal, prefix: "e")
        let model = ShareModel(makeSource: factory.make, screenRecordingGranted: { true })
        model.start(excludingWindowIDs: [])
        await drain()
        let source = factory.made[0]
        source.emit(.started(pixelWidth: 320, pixelHeight: 180, scale: 2))
        await drain()
        model.loopback = true
        source.emit(frame: try capturedFrame(index: 0, width: 100_000, height: 2))
        try await waitUntil("the share fails") { model.state != .capturing }
        guard case .failed(let message) = model.state else { return XCTFail("expected a failure, got \(model.state)") }
        XCTAssertTrue(message.hasPrefix("This Mac's hardware video encoder could not start (error "), message)
        XCTAssertTrue(message.hasSuffix("); press Retry to try again."), message)
        XCTAssertFalse(message.contains("VideoToolbox"), message)
        await model.stop()
    }

    /// The same for the loop's decoder: a setup it cannot read fails the share in one sentence.
    @MainActor
    func testALoopDecoderThatCannotStartSaysSoInOneSentence() async throws {
        let journal = Journal()
        let factory = Factory(journal: journal, prefix: "f")
        let model = ShareModel(makeSource: factory.make, screenRecordingGranted: { true })
        model.start(excludingWindowIDs: [])
        await drain()
        factory.made[0].emit(.started(pixelWidth: 320, pixelHeight: 180, scale: 2))
        await drain()
        model.loopback = true
        model.handleEncoded(EncodedFrame(seq: 0, captureHostTimeNs: 1, isKey: true, data: Data([0, 0, 0, 1, 2]),
                                         parameterSets: [Data([0, 1, 2])], codec: .hevc, width: 320, height: 180))
        guard case .failed(let message) = model.state else { return XCTFail("expected a failure, got \(model.state)") }
        XCTAssertTrue(message.hasPrefix("The video decoder could not start (error "), message)
        XCTAssertTrue(message.hasSuffix("); press Retry to try again."), message)
        await model.stop()
    }

    /// Spec 9: a setting VideoToolbox rejects is said over the picture in plain language, not with its key.
    @MainActor
    func testARejectedSettingIsSaidInPlainLanguage() async throws {
        let journal = Journal()
        let factory = Factory(journal: journal, prefix: "y")
        let model = ShareModel(makeSource: factory.make, screenRecordingGranted: { true })
        model.start(excludingWindowIDs: [])
        await drain()
        let source = factory.made[0]
        source.emit(.started(pixelWidth: 320, pixelHeight: 180, scale: 2))
        await drain()
        model.loopback = true
        source.emit(frame: try capturedFrame(index: 0))
        try await waitUntil("the loop makes an encoder") { model.encoder != nil }
        model.encoder?.setBitrate(-1)
        try await waitUntil("the rejected setting is said") { model.codecNotice != nil }
        let notice = try XCTUnwrap(model.codecNotice)
        XCTAssertTrue(notice.contains("average bitrate"), notice)
        XCTAssertFalse(notice.contains("AverageBitRate"), notice)
        XCTAssertFalse(notice.contains("DataRateLimits"), notice)
        await model.stop()
    }

    /// The encoder takes two frames at a time and turns the next one away (`VideoEncoder.encode`), and the frame turned
    /// away is the newest. Spec sections 5 and 8: the newest frame is the one that gets through. Frames that arrive back
    /// to back while two are encoding, then a source that goes still (ScreenCaptureKit sends nothing more), leave the
    /// loop showing the last frame captured, with its own capture time, not the one before it.
    @MainActor
    func testTheNewestFrameGetsThroughWhenTheEncoderIsBusyAndTheSourceGoesStill() async throws {
        let journal = Journal()
        let factory = Factory(journal: journal, prefix: "s")
        let model = ShareModel(makeSource: factory.make, screenRecordingGranted: { true })
        let view = VideoView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        model.sink.view = view
        model.start(excludingWindowIDs: [])
        await drain()
        let source = factory.made[0]
        source.emit(.started(pixelWidth: 1920, pixelHeight: 1080, scale: 2))
        await drain()
        model.loopback = true
        var frames: [CapturedFrame] = []
        for i in 0..<4 { frames.append(try solidFrame(index: i, width: 1920, height: 1080)) }
        for frame in frames { source.emit(frame: frame) }   // back to back: more than the two the encoder takes at once
        let newest = try XCTUnwrap(frames.last)
        // The source is still from here on: nothing but the model can bring the newest frame through.
        var waits = 0
        while view.pacer.held?.captureHostTimeNs != newest.captureHostTimeNs, waits < 30 {
            try await Task.sleep(for: .milliseconds(50)); waits += 1
        }
        let held = try XCTUnwrap(view.pacer.held)
        XCTAssertEqual(held.captureHostTimeNs, newest.captureHostTimeNs, "the loop shows the newest frame captured")
        XCTAssertTrue(held.compareWith === newest.pixelBuffer, "against the newest raw frame")
        XCTAssertEqual(model.state, .capturing)
        await model.stop()
    }

    /// A frame the encoder's two-in-flight cap turns away is not lost yet: it goes in as soon as a slot frees, so it does
    /// not count as dropped. Only one a newer frame replaces before then never reaches the encoder, and counts once. Four
    /// frames back to back: the encoder takes two, the third waits and the fourth replaces it, then goes in.
    @MainActor
    func testOnlyAFrameReplacedWhileTheEncoderIsBusyCountsAsDropped() async throws {
        let journal = Journal()
        let factory = Factory(journal: journal, prefix: "r")
        let model = ShareModel(makeSource: factory.make, screenRecordingGranted: { true })
        let view = VideoView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        model.sink.view = view
        model.start(excludingWindowIDs: [])
        await drain()
        let source = factory.made[0]
        source.emit(.started(pixelWidth: 1920, pixelHeight: 1080, scale: 2))
        await drain()
        model.loopback = true
        var frames: [CapturedFrame] = []
        for i in 0..<4 { frames.append(try solidFrame(index: i, width: 1920, height: 1080)) }
        for frame in frames { source.emit(frame: frame) }
        let newest = try XCTUnwrap(frames.last)
        var waits = 0
        while view.pacer.held?.captureHostTimeNs != newest.captureHostTimeNs, waits < 30 {
            try await Task.sleep(for: .milliseconds(50)); waits += 1
        }
        XCTAssertEqual(view.pacer.held?.captureHostTimeNs, newest.captureHostTimeNs, "the newest frame went in once a slot freed")
        XCTAssertEqual(model.droppedFramesTotal, 1, "only the third frame, which the fourth replaced before a slot freed")
        await model.stop()
    }

    /// The frames the encoder holds at its cap can end through `onError` instead of an output (VideoToolbox failed or
    /// dropped them, `VideoEncoder.encode`). That frees their slots as well: the newest frame, turned away at the cap,
    /// goes in then, rather than waiting for a capture frame that a still source never sends.
    @MainActor
    func testTheNewestFrameGetsThroughWhenTheFramesAheadOfItFail() async throws {
        let journal = Journal()
        let factory = Factory(journal: journal, prefix: "u")
        let model = ShareModel(makeSource: factory.make, screenRecordingGranted: { true })
        model.start(excludingWindowIDs: [])
        await drain()
        let source = factory.made[0]
        source.emit(.started(pixelWidth: 1920, pixelHeight: 1080, scale: 2))
        await drain()
        model.loopback = true
        source.emit(frame: try solidFrame(index: 0, width: 1920, height: 1080))
        var waits = 0
        while model.encoder == nil, waits < 40 { try await Task.sleep(for: .milliseconds(50)); waits += 1 }
        let encoder = try XCTUnwrap(model.encoder, "the loop makes an encoder")
        try await Task.sleep(for: .milliseconds(300))   // the first frame is through
        // From here VideoToolbox fails every frame: none reaches the model as an output, and the test reports each one
        // through the encoder's own `onError`, as VideoToolbox would.
        let reportFailure = try XCTUnwrap(encoder.onError)
        let emitted = EncodedTimes()
        encoder.onFrame = { frame in
            let time = frame.captureHostTimeNs
            Task { @MainActor in emitted.times.append(time) }
        }
        var frames: [CapturedFrame] = []
        for i in 1...4 { frames.append(try solidFrame(index: i, width: 1920, height: 1080)) }
        for frame in frames { source.emit(frame: frame) }   // back to back: more than the two the encoder takes at once
        let newest = try XCTUnwrap(frames.last)
        try await Task.sleep(for: .milliseconds(300))   // the frames the encoder took are done; the source is still
        XCTAssertFalse(emitted.times.isEmpty, "the encoder took frames")
        XCTAssertFalse(emitted.times.contains(newest.captureHostTimeNs), "the cap turned the newest frame away")

        for _ in emitted.times { reportFailure(.frameDropped) }
        waits = 0
        while !emitted.times.contains(newest.captureHostTimeNs), waits < 40 { try await Task.sleep(for: .milliseconds(50)); waits += 1 }
        XCTAssertTrue(emitted.times.contains(newest.captureHostTimeNs), "the newest frame reaches the encoder once a failure frees a slot")
        XCTAssertEqual(model.state, .capturing)
        await model.stop()
    }

    /// The evening two-Mac test of 2026-10-09: under a storm of keyframes VideoToolbox dropped ten frames in a row
    /// ("flags 3: frameDropped"), and the share failed with "Video encoding keeps failing." and Retry. A realtime
    /// encoder that lets frames go is dropping them, not failing: ten drops in a row leave the share capturing and
    /// count ten dropped frames, and do not count towards the failures. Ten real failures in a row still fail the
    /// codec.
    @MainActor
    func testFramesVideoToolboxDropsAreDropsNotFailures() async throws {
        let journal = Journal()
        let factory = Factory(journal: journal, prefix: "d")
        let model = ShareModel(makeSource: factory.make, screenRecordingGranted: { true })
        model.start(excludingWindowIDs: [])
        await drain()
        let source = factory.made[0]
        source.emit(.started(pixelWidth: 320, pixelHeight: 180, scale: 2))
        await drain()
        model.loopback = true
        source.emit(frame: try capturedFrame(index: 0))
        try await waitUntil("the loop makes an encoder") { model.encoder != nil }
        let encoder = try XCTUnwrap(model.encoder)
        try await Task.sleep(for: .milliseconds(300))   // the first frame is through
        let report = try XCTUnwrap(encoder.onError)

        let before = model.droppedFramesTotal
        for _ in 0..<10 { report(.frameDropped) }
        try await waitUntil("the ten drops are counted") { model.droppedFramesTotal == before + 10 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.state, .capturing, "ten drops in a row are not a failure")
        XCTAssertTrue(model.encoder === encoder, "the encoder goes on")

        for _ in 0..<9 { report(.encode(-12902)) }
        report(.frameDropped)                             // a drop in between neither counts nor starts the count again
        report(.encode(-12902))
        try await waitUntil("ten real failures in a row fail the codec") {
            model.state == .failed("Video encoding keeps failing.")
        }
        XCTAssertEqual(model.codecLabel, "raw")
        await model.stop()
    }

    /// Stop Sharing in the menu bar ends the stream with an error, as does a stream that stops or cannot start: the
    /// share fails and offers Retry. The session's system picker stays up, though, and a new pick starts a fresh stream
    /// on the same session (`.started`): the share resumes as a fresh one, with the card gone, the listener back and a
    /// new encoder made from the new stream's first frame.
    @MainActor
    func testANewPickAfterTheCaptureEndedResumesTheShare() async throws {
        let journal = Journal()
        let factory = Factory(journal: journal, prefix: "v")
        let model = ShareModel(makeSource: factory.make, screenRecordingGranted: { true })
        let view = VideoView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        model.sink.view = view
        model.start(excludingWindowIDs: [])
        await drain()
        let source = factory.made[0]
        source.emit(.started(pixelWidth: 320, pixelHeight: 180, scale: 2))
        await drain()
        model.loopback = true
        source.emit(frame: try capturedFrame(index: 0))
        var waits = 0
        while view.pacer.held?.compareWith == nil, waits < 40 { try await Task.sleep(for: .milliseconds(50)); waits += 1 }
        let old = try XCTUnwrap(model.encoder)
        XCTAssertNotNil(model.advertiser, "the share listens")

        source.emit(.failed(CaptureFailure(reason: .stoppedFromMenuBar, detail: "The user stopped the stream")))
        await drain()
        XCTAssertEqual(model.state, .failed("Sharing was stopped from the menu bar. Press Retry to share again."))
        XCTAssertNil(model.advertiser, "a failed share stops listening")

        source.emit(.started(pixelWidth: 320, pixelHeight: 180, scale: 2))   // a new pick, from the same session's picker
        await drain()
        XCTAssertEqual(model.state, .capturing, "a new pick resumes the share without Retry")
        XCTAssertFalse(model.failureNeedsPermission)
        XCTAssertNotNil(model.advertiser, "the resumed share listens again")
        XCTAssertNil(model.encoder, "the ended stream's encoder is let go")
        XCTAssertEqual(model.codecLabel, "raw")
        let fresh = try capturedFrame(index: 1)
        source.emit(frame: fresh)
        waits = 0
        while view.pacer.held?.compareWith !== fresh.pixelBuffer, waits < 40 { try await Task.sleep(for: .milliseconds(50)); waits += 1 }
        XCTAssertTrue(view.pacer.held?.compareWith === fresh.pixelBuffer, "the loop shows the new stream's frame, encoded and decoded")
        let made = try XCTUnwrap(model.encoder)
        XCTAssertFalse(made === old, "a new encoder")
        XCTAssertEqual(model.state, .capturing)
        XCTAssertEqual(journal.lines, ["present v0"], "the same session")
        await model.stop()
    }

    /// A new model's picker waits until the previous model's session has fully stopped (one shared system picker).
    @MainActor
    func testNextModelWaitsForThePreviousModelsStop() async {
        let journal = Journal()
        let first = Factory(journal: journal, prefix: "h")
        let gate = Gate()
        first.gates[0] = gate
        let a = ShareModel(makeSource: first.make)
        a.start(excludingWindowIDs: [])
        await drain()
        let stopping = Task { await a.stop() }
        await drain()

        let second = Factory(journal: journal, prefix: "i")
        let b = ShareModel(makeSource: second.make)
        b.start(excludingWindowIDs: [])
        await drain()
        XCTAssertEqual(journal.lines, ["present h0", "stop h0"], "the new picker appeared before the old session stopped")

        gate.open()
        await stopping.value
        await drain()
        XCTAssertEqual(journal.lines, ["present h0", "stop h0", "stopped h0", "present i0"])
        await b.stop()
    }
}
