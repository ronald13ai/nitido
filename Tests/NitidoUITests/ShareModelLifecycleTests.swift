import XCTest
import CoreVideo
import QuartzCore
@testable import NitidoCapture
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
