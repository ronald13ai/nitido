import XCTest
import AppKit
import CoreVideo
import NitidoCapture
@testable import NitidoUI

/// Stands in for VideoView: records every render, never touches Metal.
@MainActor
private final class FakeDrawing: FrameDrawing {
    var canShowFrames = true
    var drawableCount = 3
    var renderResult: VideoView.Drop?
    private(set) var renders: [(kind: FramePacer.Kind, captureHostTimeNs: UInt64)] = []
    private(set) var presented: [UInt64] = []
    /// The presented time of each entry of `presented`, for the latency it reports.
    private(set) var presentedAt: [Double] = []
    private(set) var drops: [VideoView.Drop] = []

    func render(_ frame: FramePacer.Frame, kind: FramePacer.Kind) -> VideoView.Drop? {
        renders.append((kind, frame.captureHostTimeNs))
        return renderResult
    }
    func framePresented(captureHostTimeNs: UInt64, at presentedAt: Double) {
        presented.append(captureHostTimeNs)
        self.presentedAt.append(presentedAt)
    }
    func frameDropped(_ drop: VideoView.Drop) { drops.append(drop) }
    var kinds: [FramePacer.Kind] { renders.map(\.kind) }
}

private func makeBuffer() throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(kCFAllocatorDefault, 8, 6, kCVPixelFormatType_32BGRA, nil, &buffer)
    guard status == kCVReturnSuccess, let buffer else { throw XCTSkip("CVPixelBufferCreate failed: \(status)") }
    return buffer
}

@MainActor
private func frame(_ ns: UInt64) throws -> FramePacer.Frame {
    FramePacer.Frame(pixelBuffer: try makeBuffer(), captureHostTimeNs: ns)
}

/// A FIFO display at 60 Hz driving a pacer: every committed drawable queues, and each vsync presents the oldest
/// one (its presented handler fires then). A source changing at the display rate captures one frame right after
/// each vsync. The pool holds 3 drawables, so the pacer keeps at most 2 in flight.
@MainActor
private final class VsyncLoop {
    let host = FakeDrawing()
    let pacer = FramePacer()
    private static let period = 1.0 / 60
    private var time: Double = 1
    /// Renders whose drawable the display has already presented.
    private var shown = 0
    /// Capture time and arrival order, so frames captured in the same vsync stay distinct.
    private var arrivals: [UInt64] = []
    private var presentedBeforeRun = 0
    private var arrivalsBeforeRun = 0

    init() {
        pacer.host = host
        pacer.now = { [unowned self] in self.time }
        pacer.drawableSize = CGSize(width: 800, height: 600)
    }

    /// A frame captured now.
    func arrive() throws {
        let ns = UInt64((time * 1e9).rounded()) + UInt64(arrivals.count)
        arrivals.append(ns)
        pacer.present(try frame(ns))
    }

    /// The next vsync presents the oldest committed drawable.
    func vsync() {
        time += Self.period
        guard shown < host.renders.count else { return }
        let next = host.renders[shown]
        shown += 1
        pacer.drawableReturned(kind: next.kind, captureHostTimeNs: next.captureHostTimeNs, presentedAt: time)
    }

    func run(vsyncs: Int) throws {
        presentedBeforeRun = host.presented.count
        arrivalsBeforeRun = arrivals.count
        for _ in 0..<vsyncs {
            vsync()
            try arrive()
        }
    }

    var presentedDuringRun: Int { host.presented.count - presentedBeforeRun }
    var redraws: Int { host.kinds.filter { $0 == .redraw }.count }

    /// The longest capture-to-display time reported, in vsync periods.
    var maxLatencyVsyncs: Double {
        zip(host.presented, host.presentedAt).map { ($1 - Double($0) / 1e9) / Self.period }.max() ?? 0
    }

    /// Every captured frame is reported displayed once, in capture order, except the few still queued at the end
    /// (2 in flight and 1 waiting at most).
    func assertEveryArrivalIsDisplayedInOrder(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(host.presented, Array(arrivals.prefix(host.presented.count)),
                       "displayed out of order, twice, or with frames missing", file: file, line: line)
        XCTAssertLessThanOrEqual(arrivals.count - host.presented.count, 3, "frames left undisplayed", file: file, line: line)
        XCTAssertGreaterThan(arrivals.count, arrivalsBeforeRun, file: file, line: line)
    }
}

final class FramePacerTests: XCTestCase {
    /// The reviewer's case: a still source, then the drawable changes size (the window fitted to the pick, or a
    /// move to a display with another scale). The held frame is drawn once more and is not a new display.
    @MainActor
    func testSizeChangeRedrawsTheHeldFrameOnceWithoutReportingItPresented() throws {
        let host = FakeDrawing()
        let pacer = FramePacer()
        pacer.host = host
        pacer.drawableSize = CGSize(width: 1440, height: 900)
        pacer.present(try frame(100))
        XCTAssertEqual(host.kinds, [.live])
        pacer.drawableReturned(kind: .live, captureHostTimeNs: 100, presentedAt: 1.0)
        XCTAssertEqual(host.presented, [100])

        pacer.drawableSize = CGSize(width: 1440, height: 900)
        XCTAssertEqual(host.kinds, [.live], "the same size is not a change")

        pacer.drawableSize = CGSize(width: 3200, height: 2400)
        XCTAssertEqual(host.kinds, [.live, .redraw])
        XCTAssertEqual(host.renders.last?.captureHostTimeNs, 100, "the redraw draws the held frame")
        pacer.drawableReturned(kind: .redraw, captureHostTimeNs: 100, presentedAt: 1.1)
        XCTAssertEqual(host.presented, [100], "a redraw is not a display or a latency sample")
        XCTAssertTrue(host.drops.isEmpty)
        XCTAssertEqual(pacer.inFlight, 0)
    }

    /// A frame that arrives while the window is minimized, covered or hidden is kept and drawn when it shows.
    @MainActor
    func testFrameSkippedWhileHiddenIsKeptAndDrawnWhenTheWindowShows() throws {
        let host = FakeDrawing()
        let pacer = FramePacer()
        pacer.host = host
        pacer.drawableSize = CGSize(width: 800, height: 600)
        pacer.present(try frame(1))
        pacer.drawableReturned(kind: .live, captureHostTimeNs: 1, presentedAt: 1.0)

        host.canShowFrames = false
        pacer.present(try frame(2))
        XCTAssertEqual(host.drops, [.hidden])
        XCTAssertEqual(host.kinds, [.live])

        host.canShowFrames = true
        pacer.redraw()
        XCTAssertEqual(host.kinds, [.live, .redraw])
        XCTAssertEqual(host.renders.last?.captureHostTimeNs, 2, "the newest frame, not the one on screen")
        pacer.drawableReturned(kind: .redraw, captureHostTimeNs: 2, presentedAt: 2.0)
        XCTAssertEqual(host.presented, [1])
    }

    /// A redraw never exceeds the frames-in-flight cap: it waits for the next drawable, then runs once.
    @MainActor
    func testRedrawAtTheCapWaitsForTheNextDrawable() throws {
        let host = FakeDrawing()
        let pacer = FramePacer()
        pacer.host = host
        pacer.now = { 10 }
        pacer.drawableSize = CGSize(width: 800, height: 600)
        pacer.present(try frame(1))
        pacer.present(try frame(2))
        XCTAssertEqual(pacer.inFlight, 2)

        pacer.drawableSize = CGSize(width: 1600, height: 1200)
        XCTAssertEqual(host.kinds, [.live, .live], "no third drawable while two are in flight")
        XCTAssertTrue(host.drops.isEmpty, "a waiting redraw is not a dropped frame")

        pacer.drawableReturned(kind: .live, captureHostTimeNs: 1, presentedAt: 1.0)
        XCTAssertEqual(host.kinds, [.live, .live, .redraw])
        XCTAssertEqual(host.renders.last?.captureHostTimeNs, 2)
        XCTAssertEqual(pacer.inFlight, 2)

        pacer.drawableReturned(kind: .live, captureHostTimeNs: 2, presentedAt: 1.1)
        pacer.drawableReturned(kind: .redraw, captureHostTimeNs: 2, presentedAt: 1.2)
        XCTAssertEqual(host.kinds.count, 3, "the redraw ran once")
        XCTAssertEqual(host.presented, [1, 2])
    }

    /// A live frame drawn after a redraw was queued already shows the new size: the queued redraw is dropped.
    @MainActor
    func testLiveFrameSupersedesAQueuedRedraw() throws {
        let host = FakeDrawing()
        let pacer = FramePacer()
        pacer.host = host
        pacer.now = { 10 }
        pacer.drawableSize = CGSize(width: 800, height: 600)
        pacer.present(try frame(1))
        pacer.present(try frame(2))
        pacer.drawableSize = CGSize(width: 1600, height: 1200)   // queued: two in flight
        host.drawableCount = 4                                   // room for one more live frame
        pacer.present(try frame(3))
        XCTAssertEqual(host.kinds, [.live, .live, .live])
        pacer.drawableReturned(kind: .live, captureHostTimeNs: 1, presentedAt: 1.0)
        XCTAssertEqual(host.kinds, [.live, .live, .live], "frame 3 already drew at the new size")
    }

    /// A live frame is dropped as backlog only when a newer one replaces it while it waits at the cap, and a
    /// discarded live drawable is a drop, never a display; a discarded redraw is neither.
    @MainActor
    func testLiveFramesKeepTheirDropAccounting() throws {
        let host = FakeDrawing()
        let pacer = FramePacer()
        pacer.host = host
        pacer.now = { 10 }
        pacer.drawableSize = CGSize(width: 800, height: 600)
        pacer.present(try frame(1))
        pacer.present(try frame(2))
        pacer.present(try frame(3))                              // waits at the cap
        XCTAssertTrue(host.drops.isEmpty, "a frame waiting for a drawable is not dropped")
        pacer.present(try frame(4))                              // replaces frame 3 before it was drawn
        XCTAssertEqual(host.drops, [.backlog])
        pacer.drawableReturned(kind: .live, captureHostTimeNs: 1, presentedAt: 0)
        XCTAssertEqual(host.drops, [.backlog, .notPresented])
        XCTAssertTrue(host.presented.isEmpty)
        XCTAssertEqual(host.renders.map(\.captureHostTimeNs), [1, 2, 4], "frame 3 is never drawn")

        pacer.drawableReturned(kind: .live, captureHostTimeNs: 2, presentedAt: 1.1)
        pacer.drawableSize = CGSize(width: 1600, height: 1200)  // a redraw of frame 4
        XCTAssertEqual(host.kinds, [.live, .live, .live, .redraw])
        pacer.drawableReturned(kind: .live, captureHostTimeNs: 4, presentedAt: 1.2)
        pacer.drawableReturned(kind: .redraw, captureHostTimeNs: 4, presentedAt: 0)
        XCTAssertEqual(host.drops, [.backlog, .notPresented], "a discarded redraw is not a dropped frame")
        XCTAssertEqual(host.presented, [2, 4])
        XCTAssertEqual(pacer.inFlight, 0)
    }

    /// The last frame of a burst arrives while two drawables are in flight, then the source goes still (it only
    /// sends changed frames). The frame waits as a live frame and is drawn when the next drawable comes back: it
    /// is a display with its real latency, wait included, and never a drop.
    @MainActor
    func testLiveFrameAtTheCapWaitsAndIsDrawnLiveWhenTheNextDrawableReturns() throws {
        let host = FakeDrawing()
        let pacer = FramePacer()
        pacer.host = host
        pacer.now = { 10 }
        pacer.drawableSize = CGSize(width: 800, height: 600)
        pacer.present(try frame(1))
        pacer.present(try frame(2))
        pacer.present(try frame(3))
        XCTAssertEqual(host.kinds, [.live, .live], "no third drawable while two are in flight")
        XCTAssertTrue(host.drops.isEmpty, "waiting for a drawable is not a drop")

        pacer.drawableReturned(kind: .live, captureHostTimeNs: 1, presentedAt: 1.0)
        XCTAssertEqual(host.kinds, [.live, .live, .live], "drawn as the live frame it is, not as a redraw")
        XCTAssertEqual(host.renders.last?.captureHostTimeNs, 3, "the newest frame reaches the screen")

        pacer.drawableReturned(kind: .live, captureHostTimeNs: 2, presentedAt: 1.1)
        pacer.drawableReturned(kind: .live, captureHostTimeNs: 3, presentedAt: 1.2)
        XCTAssertEqual(host.kinds.count, 3, "drawn once")
        XCTAssertEqual(host.presented, [1, 2, 3], "counted as displayed")
        XCTAssertEqual(host.presentedAt.last, 1.2, "its latency is measured at the time it was really shown")
        XCTAssertTrue(host.drops.isEmpty)
        XCTAssertEqual(pacer.inFlight, 0)
    }

    /// Two frames arrive while two drawables are in flight: the first waits, the second replaces it. Only the
    /// replaced one is a drop, once, and the newer one is drawn live when the next drawable comes back.
    @MainActor
    func testANewerFrameReplacesTheWaitingFrameWhichIsDroppedOnce() throws {
        let host = FakeDrawing()
        let pacer = FramePacer()
        pacer.host = host
        pacer.now = { 10 }
        pacer.drawableSize = CGSize(width: 800, height: 600)
        pacer.present(try frame(1))
        pacer.present(try frame(2))
        pacer.present(try frame(3))
        pacer.present(try frame(4))
        XCTAssertEqual(host.drops, [.backlog])
        XCTAssertEqual(host.kinds, [.live, .live])

        pacer.drawableReturned(kind: .live, captureHostTimeNs: 1, presentedAt: 1.0)
        XCTAssertEqual(host.kinds, [.live, .live, .live])
        XCTAssertEqual(host.renders.last?.captureHostTimeNs, 4)
        pacer.drawableReturned(kind: .live, captureHostTimeNs: 2, presentedAt: 1.1)
        pacer.drawableReturned(kind: .live, captureHostTimeNs: 4, presentedAt: 1.2)
        XCTAssertEqual(host.presented, [1, 2, 4])
        XCTAssertEqual(host.drops, [.backlog], "the replaced frame is dropped once, the newer one is not")
        XCTAssertEqual(host.kinds.count, 3)
    }

    /// A newer live frame that finds a free drawable replaces the waiting one: the waiting one is dropped and no
    /// late draw follows, since the newest picture is already on its way to the screen.
    @MainActor
    func testLiveFrameDrawnWhileAnotherWaitsDropsTheWaitingOneAndNothingFollows() throws {
        let host = FakeDrawing()
        let pacer = FramePacer()
        pacer.host = host
        pacer.now = { 10 }
        pacer.drawableSize = CGSize(width: 800, height: 600)
        pacer.present(try frame(1))
        pacer.present(try frame(2))
        pacer.present(try frame(3))                              // waits at the cap
        host.drawableCount = 4                                   // room for one more live frame
        pacer.present(try frame(4))
        XCTAssertEqual(host.kinds, [.live, .live, .live])
        XCTAssertEqual(host.drops, [.backlog])
        pacer.drawableReturned(kind: .live, captureHostTimeNs: 1, presentedAt: 1.0)
        XCTAssertEqual(host.kinds, [.live, .live, .live], "frame 4 is already the newest on screen")
        XCTAssertEqual(host.presented, [1])
    }

    /// The drawable changes size while a live frame waits at the cap. The frame stays live: when the next
    /// drawable comes back it is drawn once, at the new size, and counted as displayed; no redraw takes its slot.
    @MainActor
    func testResizeWhileALiveFrameWaitsKeepsItLive() throws {
        let host = FakeDrawing()
        let pacer = FramePacer()
        pacer.host = host
        pacer.now = { 10 }
        pacer.drawableSize = CGSize(width: 800, height: 600)
        pacer.present(try frame(1))
        pacer.present(try frame(2))
        pacer.present(try frame(3))
        pacer.drawableSize = CGSize(width: 1600, height: 1200)
        XCTAssertEqual(host.kinds, [.live, .live])

        pacer.drawableReturned(kind: .live, captureHostTimeNs: 1, presentedAt: 1.0)
        XCTAssertEqual(host.kinds, [.live, .live, .live])
        XCTAssertEqual(host.renders.last?.captureHostTimeNs, 3)
        pacer.drawableReturned(kind: .live, captureHostTimeNs: 2, presentedAt: 1.1)
        pacer.drawableReturned(kind: .live, captureHostTimeNs: 3, presentedAt: 1.2)
        XCTAssertEqual(host.kinds.count, 3, "nothing else drawn")
        XCTAssertEqual(host.presented, [1, 2, 3])
        XCTAssertTrue(host.drops.isEmpty)
    }

    /// A live frame waits at the cap, then a drawable is free before any returns (the pool grew) and the window
    /// shows again. The reveal draws the waiting frame as the live frame it is, once: no uncounted redraw now
    /// and no second draw when the next drawable comes back.
    @MainActor
    func testRevealWithAFreeDrawableDrawsTheWaitingFrameLiveOnce() throws {
        let host = FakeDrawing()
        let pacer = FramePacer()
        pacer.host = host
        pacer.now = { 10 }
        pacer.drawableSize = CGSize(width: 800, height: 600)
        pacer.present(try frame(1))
        pacer.present(try frame(2))
        pacer.present(try frame(3))                              // waits at the cap
        host.drawableCount = 4
        pacer.redraw()
        XCTAssertEqual(host.kinds, [.live, .live, .live])
        XCTAssertEqual(host.renders.last?.captureHostTimeNs, 3)

        pacer.drawableReturned(kind: .live, captureHostTimeNs: 1, presentedAt: 1.0)
        pacer.drawableReturned(kind: .live, captureHostTimeNs: 2, presentedAt: 1.1)
        pacer.drawableReturned(kind: .live, captureHostTimeNs: 3, presentedAt: 1.2)
        XCTAssertEqual(host.kinds.count, 3, "drawn once")
        XCTAssertEqual(host.presented, [1, 2, 3])
        XCTAssertTrue(host.drops.isEmpty)
    }

    /// The reviewer's loop: a FIFO display at 60 Hz and a source changing at the display rate, one frame per
    /// vsync. Undisturbed, every frame is displayed one vsync after capture.
    @MainActor
    func testVsyncLoopSteadyArrivalsAreAllDisplayed() throws {
        let loop = VsyncLoop()
        try loop.arrive()
        try loop.run(vsyncs: 60)
        XCTAssertEqual(loop.presentedDuringRun, 60)
        XCTAssertTrue(loop.host.drops.isEmpty)
        XCTAssertEqual(loop.redraws, 0)
        XCTAssertEqual(loop.maxLatencyVsyncs, 1, accuracy: 0.001)
        loop.assertEveryArrivalIsDisplayedInOrder()
    }

    /// Same loop after a 3-frame burst (the third meets the cap). Before the fix, every later frame met the cap
    /// too, was counted as dropped and drawn as an uncounted redraw: presented 2, dropped 61, redraws 60.
    /// Every frame must count as displayed, none as dropped, and the latency must include the extra wait.
    @MainActor
    func testVsyncLoopAfterABurstCountsEveryFrameAsDisplayed() throws {
        let loop = VsyncLoop()
        try loop.arrive()
        try loop.arrive()
        try loop.arrive()
        try loop.run(vsyncs: 60)
        XCTAssertEqual(loop.presentedDuringRun, 60, "one live frame shown per vsync")
        XCTAssertTrue(loop.host.drops.isEmpty, "\(loop.host.drops.count) frames counted as dropped")
        XCTAssertEqual(loop.redraws, 0)
        XCTAssertLessThanOrEqual(loop.maxLatencyVsyncs, 3.001, "two drawables queued ahead plus the wait")
        loop.assertEveryArrivalIsDisplayedInOrder()
    }

    /// Same loop after a 2-frame burst and one resize redraw (the window fitted to the pick while the shared
    /// window changes). The redraw takes one vsync; every captured frame is still displayed and none dropped.
    @MainActor
    func testVsyncLoopAfterABurstAndAResizeCountsEveryFrameAsDisplayed() throws {
        let loop = VsyncLoop()
        try loop.arrive()
        try loop.arrive()
        loop.pacer.drawableSize = CGSize(width: 1600, height: 1200)
        try loop.run(vsyncs: 60)
        XCTAssertEqual(loop.presentedDuringRun, 59, "every vsync shows a live frame except the one showing the redraw")
        XCTAssertTrue(loop.host.drops.isEmpty, "\(loop.host.drops.count) frames counted as dropped")
        XCTAssertEqual(loop.redraws, 1, "the resize redraw only")
        XCTAssertLessThanOrEqual(loop.maxLatencyVsyncs, 3.001)
        loop.assertEveryArrivalIsDisplayedInOrder()
    }

    /// No drawable back for over a second: the count resets and drawing resumes (a lost presented handler).
    @MainActor
    func testStalledBacklogResetsAfterOneSecond() throws {
        let host = FakeDrawing()
        let pacer = FramePacer()
        pacer.host = host
        var clock: CFTimeInterval = 10
        pacer.now = { clock }
        pacer.drawableSize = CGSize(width: 800, height: 600)
        pacer.present(try frame(1))
        pacer.present(try frame(2))
        clock = 11.5
        pacer.present(try frame(3))
        XCTAssertEqual(host.kinds, [.live, .live, .live])
        XCTAssertEqual(pacer.inFlight, 1)
    }

    /// A redraw that fails to render is shown like any render failure; one without a drawable is only logged.
    @MainActor
    func testRedrawFailuresAreReportedOnlyWhenTheyAreRenderFailures() throws {
        let host = FakeDrawing()
        let pacer = FramePacer()
        pacer.host = host
        pacer.drawableSize = CGSize(width: 800, height: 600)
        pacer.present(try frame(1))
        pacer.drawableReturned(kind: .live, captureHostTimeNs: 1, presentedAt: 1.0)

        host.renderResult = .noDrawable
        pacer.redraw()
        XCTAssertTrue(host.drops.isEmpty)
        host.renderResult = .failed("boom")
        pacer.redraw()
        XCTAssertEqual(host.drops, [.failed("boom")])
        XCTAssertEqual(pacer.inFlight, 0, "nothing was committed")
    }

    /// Releasing the held frame (the share stopped) leaves nothing to redraw.
    @MainActor
    func testReleaseLeavesNothingToRedraw() throws {
        let host = FakeDrawing()
        let pacer = FramePacer()
        pacer.host = host
        pacer.drawableSize = CGSize(width: 800, height: 600)
        pacer.present(try frame(1))
        pacer.releaseHeldFrame()
        XCTAssertNil(pacer.held)
        pacer.drawableSize = CGSize(width: 1600, height: 1200)
        pacer.redraw()
        XCTAssertEqual(host.kinds, [.live])
    }
}

final class VideoViewHeldFrameTests: XCTestCase {
    /// A frame pushed while the view has no visible window is kept (and reported hidden); leaving the window
    /// hands it back.
    @MainActor
    func testLeavingTheWindowReleasesTheHeldFrame() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let view = VideoView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = view
        let drops = DropLog()
        view.onDropped = { drops.items.append($0) }

        view.present(try makeBuffer(), captureHostTimeNs: 5)
        XCTAssertEqual(drops.items, [.hidden], "a window never ordered on screen is not visible")
        XCTAssertEqual(view.pacer.held?.captureHostTimeNs, 5)

        window.contentView = nil
        XCTAssertNil(view.pacer.held)
    }

    /// Stop releases the frame the view keeps for redraws.
    @MainActor
    func testShareStopReleasesTheHeldFrame() async throws {
        let model = ShareModel(makeSource: { NeverSource() }, screenRecordingGranted: { true })
        let view = VideoView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        model.sink.view = view
        model.sink.push(try makeBuffer(), captureHostTimeNs: 9)
        XCTAssertEqual(view.pacer.held?.captureHostTimeNs, 9)
        await model.stop()
        XCTAssertNil(view.pacer.held)
    }
}

@MainActor
private final class DropLog {
    var items: [VideoView.Drop] = []
}

/// A capture source that never emits; enough for a model that is only stopped.
@MainActor
private final class NeverSource: CaptureSource {
    let frames = AsyncStream<CapturedFrame> { _ in }
    let events = AsyncStream<CaptureEvent> { _ in }
    func presentPicker(excludingWindowIDs: [CGWindowID]) {}
    func stop() async {}
}
