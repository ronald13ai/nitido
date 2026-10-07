import XCTest
import CoreVideo
import QuartzCore
import CoreText
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

/// Mean absolute difference per colour channel between two BGRA buffers of the same size (0...255).
private func meanError(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Double {
    let width = min(CVPixelBufferGetWidth(a), CVPixelBufferGetWidth(b))
    let height = min(CVPixelBufferGetHeight(a), CVPixelBufferGetHeight(b))
    CVPixelBufferLockBaseAddress(a, .readOnly); CVPixelBufferLockBaseAddress(b, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(a, .readOnly); CVPixelBufferUnlockBaseAddress(b, .readOnly) }
    let pa = CVPixelBufferGetBaseAddress(a)!.assumingMemoryBound(to: UInt8.self)
    let pb = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self)
    let sa = CVPixelBufferGetBytesPerRow(a), sb = CVPixelBufferGetBytesPerRow(b)
    var total = 0
    for y in 0..<height {
        for x in 0..<width {
            for c in 0..<3 { total += abs(Int(pa[y * sa + x * 4 + c]) - Int(pb[y * sb + x * 4 + c])) }
        }
    }
    return Double(total) / Double(width * height * 3)
}

/// Counts the frames the model hands to the view: a view outside a window reports each one as hidden.
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

final class ShareModelLifecycleTests: XCTestCase {
    @MainActor
    private func drain() async {
        for _ in 0..<50 { await Task.yield() }
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
        let model = ShareModel(makeSource: factory.make)
        model.start(excludingWindowIDs: [7])
        await drain()
        factory.made[0].emit(.failed("The stream stopped."))
        await drain()
        XCTAssertEqual(model.state, .failed("The stream stopped."))

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
        XCTAssertEqual(model.state, .failed("The stream stopped."))
        XCTAssertFalse(model.failureNeedsPermission)
        await model.stop()
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
        for seq in 0..<9 { model.handleEncoded(unreadable(UInt32(seq))) }
        XCTAssertEqual(model.state, .capturing, "nine throws in a row leave the share running")
        model.handleEncoded(key)
        for seq in 10..<19 { model.handleEncoded(unreadable(UInt32(seq))) }
        XCTAssertEqual(model.state, .capturing, "a frame decoded in between starts the count again")
        model.handleEncoded(unreadable(19))
        XCTAssertEqual(model.state, .failed("Video decoding keeps failing."))
        XCTAssertEqual(model.codecLabel, "raw")
        XCTAssertNil(model.codecMs)
        // The snapshot loop publishes the dropped figure every 250 ms.
        var waits = 0
        while model.snapshot.droppedLastSecond == 0, waits < 20 { try await Task.sleep(for: .milliseconds(50)); waits += 1 }
        XCTAssertGreaterThanOrEqual(model.snapshot.droppedLastSecond, 19, "every throw counts as a dropped frame")
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
