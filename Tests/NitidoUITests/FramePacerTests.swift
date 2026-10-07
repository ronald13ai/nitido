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
    /// The time a render is committed at. The display simulation sets it; unit tests leave it at 0.
    var clock: () -> Double = { 0 }
    private(set) var renders: [(kind: FramePacer.Kind, captureHostTimeNs: UInt64, committedAt: Double)] = []
    private(set) var presented: [UInt64] = []
    /// The presented time of each entry of `presented`, for the latency it reports.
    private(set) var presentedAt: [Double] = []
    private(set) var drops: [VideoView.Drop] = []

    /// Every frame handed to `render`, with the comparison it carries.
    private(set) var frames: [FramePacer.Frame] = []

    func render(_ frame: FramePacer.Frame, kind: FramePacer.Kind) -> VideoView.Drop? {
        renders.append((kind, frame.captureHostTimeNs, clock()))
        frames.append(frame)
        return renderResult
    }
    func framePresented(captureHostTimeNs: UInt64, at presentedAt: Double) {
        presented.append(captureHostTimeNs)
        self.presentedAt.append(presentedAt)
    }
    func frameDropped(_ drop: VideoView.Drop) { drops.append(drop) }
    var kinds: [FramePacer.Kind] { renders.map(\.kind) }
}

/// Collects the late draws a pacer schedules, so a unit test fires them by hand.
@MainActor
private final class Timers {
    private(set) var delays: [CFTimeInterval] = []
    private var actions: [@MainActor @Sendable () -> Void] = []
    var count: Int { actions.count }

    func install(on pacer: FramePacer) {
        pacer.schedule = { [unowned self] delay, action in
            delays.append(delay)
            actions.append(action)
        }
    }

    func fireAll() {
        let due = actions
        actions = []
        due.forEach { $0() }
    }
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

/// A display and a capture source in simulated time, driving a real FramePacer through the FrameDrawing seam.
///
/// - The display refreshes every `period`. A drawable committed before a refresh can be shown `depth` refreshes
///   later at the earliest (1: at that refresh; 2: a compositor that keeps it one refresh more), oldest first and
///   one per refresh, as with display sync on. Its presented handler reaches the main actor `handlerDelay` after
///   the refresh and reports the refresh time.
/// - The source changes at every `sourceEvery`-th refresh. Each frame carries that refresh as its capture time,
///   as ScreenCaptureKit's display time does, and reaches the main actor `arrivalPhase` after it.
/// - Main-actor work (arrivals, presented handlers, the pacer's late draws) waits while the main thread is stalled.
///   Of the frames that arrive during a stall, the first (already handed to the waiting frames loop) and the newest
///   (the capture stream keeps one buffered) reach the pacer; the ones between are lost before it sees them.
@MainActor
private final class DisplaySim {
    struct Config {
        var period = 1.0 / 60
        var depth = 1
        var arrivalPhase = 0.002
        var handlerDelay = 0.0005
        var sourceEvery = 1
    }

    private struct Event {
        let time: Double
        let seq: Int
        let arrival: Bool
        let action: @MainActor () -> Void
    }

    let config: Config
    let host = FakeDrawing()
    let pacer = FramePacer()
    private let buffer: CVPixelBuffer
    /// Main-actor time.
    private(set) var clock: Double = 1
    /// The last refresh run.
    private(set) var refresh = 0
    private var sourceStopsAfter = Int.max
    private var events: [Event] = []
    private var seq = 0
    private var stalls: [(start: Double, end: Double)] = []
    private var stallsWithAFrameThrough: Set<Int> = []
    /// Renders already shown, in commit order.
    private var shown = 0
    /// Capture times of every frame handed to the pacer, in order.
    private(set) var delivered: [UInt64] = []
    /// Frames lost in a stall before they reached the pacer.
    private(set) var lost = 0

    init(_ config: Config = Config()) throws {
        self.config = config
        buffer = try makeBuffer()
        pacer.host = host
        pacer.now = { [unowned self] in clock }
        pacer.schedule = { [unowned self] delay, action in add(at: clock + delay, arrival: false, action) }
        host.clock = { [unowned self] in clock }
        pacer.drawableSize = CGSize(width: 800, height: 600)
    }

    func time(ofRefresh j: Int) -> Double { 1 + Double(j) * config.period }

    /// Runs `count` more refreshes and the main-actor work between them.
    func run(refreshes count: Int) {
        let last = refresh + count
        while true {
            let nextRefresh = time(ofRefresh: refresh + 1)
            if let i = nextEventIndex(), effective(events[i].time) < nextRefresh {
                runEvent(at: i)
            } else if refresh < last {
                refresh += 1
                runRefresh()
            } else {
                return
            }
        }
    }

    /// `count` extra frames reach the pacer right now, as after a hiccup upstream.
    func burst(_ count: Int) {
        for i in 1...count { scheduleArrival(at: clock + Double(i) * 0.0001, capturedAt: clock) }
    }

    /// The main thread is busy for `duration` seconds, starting `delay` from now.
    func stall(after delay: Double, for duration: Double) {
        stalls.append((clock + delay, clock + delay + duration))
    }

    /// The source stops changing after the current refresh.
    func stopSource() { sourceStopsAfter = refresh }

    /// Capture-to-display latency of every frame shown, in refreshes.
    var latencies: [(captureNs: UInt64, refreshes: Double)] {
        zip(host.presented, host.presentedAt).map { ($0, ($1 - Double($0) / 1e9) / config.period) }
    }

    /// Latencies of the frames captured at or after refresh `j`.
    func latencies(capturedFromRefresh j: Int) -> [Double] {
        let from = UInt64((time(ofRefresh: j) * 1e9).rounded()) - 1
        return latencies.filter { $0.captureNs >= from }.map(\.refreshes)
    }

    var redraws: Int { host.kinds.filter { $0 == .redraw }.count }
    var backlogDrops: Int { host.drops.filter { $0 == .backlog }.count }
    var lastDelivered: UInt64? { delivered.last }

    /// Every frame handed to the pacer is displayed once in capture order, dropped once, or still on its way.
    func assertAccounting(file: StaticString = #filePath, line: UInt = #line) {
        let drops = host.drops.filter { $0 != .hidden }.count
        let notPresented = host.drops.filter { $0 == .notPresented }.count
        let liveRenders = host.renders.filter { $0.kind == .live }.map(\.captureHostTimeNs)
        let outstanding = liveRenders.count - host.presented.count - notPresented
        let waiting = pacer.pending == .live ? 1 : 0
        XCTAssertEqual(delivered.count, host.presented.count + drops + outstanding + waiting,
                       "a frame went missing or was counted twice", file: file, line: line)
        XCTAssertEqual(Set(liveRenders).count, liveRenders.count, "a frame was drawn live twice", file: file, line: line)
        XCTAssertEqual(host.presented, host.presented.sorted(), "displayed out of capture order", file: file, line: line)
        XCTAssertTrue(Set(host.presented).isSubset(of: Set(delivered)), file: file, line: line)
    }

    private func add(at time: Double, arrival: Bool, _ action: @escaping @MainActor () -> Void) {
        seq += 1
        events.append(Event(time: time, seq: seq, arrival: arrival, action: action))
    }

    private func scheduleArrival(at time: Double, capturedAt capture: Double) {
        add(at: time, arrival: true) { [unowned self] in
            // Unique and increasing even for frames of one burst, a few nanoseconds apart.
            let ns = UInt64((capture * 1e9).rounded()) + UInt64(delivered.count)
            delivered.append(ns)
            pacer.present(FramePacer.Frame(pixelBuffer: buffer, captureHostTimeNs: ns))
        }
    }

    /// When main-actor work due at `t` really runs.
    private func effective(_ t: Double) -> Double {
        for s in stalls where t >= s.start && t < s.end { return s.end }
        return t
    }

    private func nextEventIndex() -> Int? {
        events.indices.min { a, b in
            let ta = effective(events[a].time), tb = effective(events[b].time)
            return ta != tb ? ta < tb : events[a].seq < events[b].seq
        }
    }

    private func runEvent(at i: Int) {
        let event = events.remove(at: i)
        clock = max(clock, effective(event.time))
        if event.arrival, lostInStall(event) { lost += 1; return }
        event.action()
    }

    private func lostInStall(_ event: Event) -> Bool {
        guard let s = stalls.firstIndex(where: { event.time >= $0.start && event.time < $0.end }) else { return false }
        if stallsWithAFrameThrough.insert(s).inserted { return false }
        return events.contains { $0.arrival && $0.time >= stalls[s].start && $0.time < stalls[s].end }
    }

    private func runRefresh() {
        let t = time(ofRefresh: refresh)
        if shown < host.renders.count {
            let r = host.renders[shown]
            let firstRefreshAfterCommit = Int(((r.committedAt - 1) / config.period).rounded(.down)) + 1
            if refresh >= firstRefreshAfterCommit + config.depth - 1 {
                shown += 1
                add(at: t + config.handlerDelay, arrival: false) { [unowned self] in
                    pacer.drawableReturned(kind: r.kind, captureHostTimeNs: r.captureHostTimeNs, presentedAt: t)
                }
            }
        }
        if refresh % config.sourceEvery == 0, refresh <= sourceStopsAfter {
            scheduleArrival(at: t + config.arrivalPhase, capturedAt: t)
        }
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

    /// Codec loop: the comparison rides on the held frame, so a redraw after a resize shows the same raw frame and
    /// divider as the live draw did, not the decoded picture alone.
    @MainActor
    func testRedrawShowsTheSameComparison() throws {
        let host = FakeDrawing()
        let pacer = FramePacer()
        pacer.host = host
        pacer.drawableSize = CGSize(width: 1440, height: 900)
        let raw = try makeBuffer()
        pacer.present(FramePacer.Frame(pixelBuffer: try makeBuffer(), captureHostTimeNs: 100, compareWith: raw, divider: 0.3))
        pacer.drawableReturned(kind: .live, captureHostTimeNs: 100, presentedAt: 1.0)
        pacer.drawableSize = CGSize(width: 3200, height: 2400)
        XCTAssertEqual(host.kinds, [.live, .redraw])
        for drawn in host.frames {
            XCTAssertTrue(drawn.compareWith === raw, "every draw compares against the same raw frame")
            XCTAssertEqual(drawn.divider, 0.3)
        }
    }

    /// A still source sends no frame to carry a divider move: the held comparison is drawn again at once with the new
    /// divider, as a redraw (not a displayed frame). The same divider, or a frame without a comparison, draws nothing.
    @MainActor
    func testMovingTheDividerRedrawsTheHeldComparison() throws {
        let host = FakeDrawing()
        let pacer = FramePacer()
        pacer.host = host
        pacer.drawableSize = CGSize(width: 1440, height: 900)
        let raw = try makeBuffer()
        pacer.present(FramePacer.Frame(pixelBuffer: try makeBuffer(), captureHostTimeNs: 100, compareWith: raw, divider: 0.5))
        pacer.drawableReturned(kind: .live, captureHostTimeNs: 100, presentedAt: 1.0)
        pacer.moveDivider(to: 0.2)
        XCTAssertEqual(host.kinds, [.live, .redraw])
        XCTAssertTrue(host.frames.last?.compareWith === raw)
        XCTAssertEqual(host.frames.last?.divider, 0.2)
        XCTAssertEqual(pacer.held?.divider, 0.2, "later redraws keep the new divider")
        pacer.drawableReturned(kind: .redraw, captureHostTimeNs: 100, presentedAt: 2.0)
        XCTAssertEqual(host.presented, [100], "a divider move is not a displayed frame")
        pacer.moveDivider(to: 0.2)
        XCTAssertEqual(host.kinds, [.live, .redraw], "the same divider draws nothing")

        pacer.present(try frame(200))
        pacer.drawableReturned(kind: .live, captureHostTimeNs: 200, presentedAt: 3.0)
        pacer.moveDivider(to: 0.7)
        XCTAssertEqual(host.kinds, [.live, .redraw, .live], "a frame without a comparison is not drawn again")
        XCTAssertNil(pacer.held?.compareWith)
    }

    /// Divider moves while a drawable is in flight wait at the cap and are drawn once, with the last divider.
    @MainActor
    func testDividerMovesAtTheCapAreDrawnOnceWithTheLastDivider() throws {
        let host = FakeDrawing()
        let pacer = FramePacer()
        pacer.host = host
        pacer.drawableSize = CGSize(width: 1440, height: 900)
        pacer.present(FramePacer.Frame(pixelBuffer: try makeBuffer(), captureHostTimeNs: 100, compareWith: try makeBuffer(), divider: 0.5))
        pacer.moveDivider(to: 0.4)
        pacer.moveDivider(to: 0.6)
        XCTAssertEqual(host.kinds, [.live], "one drawable in flight: the moves wait")
        pacer.drawableReturned(kind: .live, captureHostTimeNs: 100, presentedAt: 1.0)
        XCTAssertEqual(host.kinds, [.live, .redraw])
        XCTAssertEqual(host.frames.last?.divider, 0.6)
    }

    /// The loop turned off: the raw frame takes the held comparison's place and is drawn at once, alone, as a redraw;
    /// a decoded frame still waiting for a drawable is drawn as the raw frame instead, once, and counted as displayed.
    @MainActor
    func testReplacingTheHeldFrameDrawsTheRawFrameAlone() throws {
        let host = FakeDrawing()
        let pacer = FramePacer()
        pacer.host = host
        pacer.drawableSize = CGSize(width: 1440, height: 900)
        pacer.present(FramePacer.Frame(pixelBuffer: try makeBuffer(), captureHostTimeNs: 100, compareWith: try makeBuffer(), divider: 0.5))
        pacer.drawableReturned(kind: .live, captureHostTimeNs: 100, presentedAt: 1.0)
        let newest = try makeBuffer()
        pacer.replaceHeld(with: FramePacer.Frame(pixelBuffer: newest, captureHostTimeNs: 150))
        XCTAssertEqual(host.kinds, [.live, .redraw])
        XCTAssertTrue(host.frames.last?.pixelBuffer === newest)
        XCTAssertNil(host.frames.last?.compareWith)
        XCTAssertTrue(pacer.held?.pixelBuffer === newest, "later redraws show the raw frame")
        pacer.drawableReturned(kind: .redraw, captureHostTimeNs: 150, presentedAt: 2.0)
        XCTAssertEqual(host.presented, [100])

        pacer.present(FramePacer.Frame(pixelBuffer: try makeBuffer(), captureHostTimeNs: 300, compareWith: try makeBuffer(), divider: 0.5))
        pacer.present(FramePacer.Frame(pixelBuffer: try makeBuffer(), captureHostTimeNs: 316, compareWith: try makeBuffer(), divider: 0.5))
        XCTAssertEqual(pacer.pending, .live, "the second decoded frame waits for a drawable")
        let raw = try makeBuffer()
        pacer.replaceHeld(with: FramePacer.Frame(pixelBuffer: raw, captureHostTimeNs: 316))
        pacer.drawableReturned(kind: .live, captureHostTimeNs: 300, presentedAt: 3.0)
        XCTAssertEqual(host.kinds, [.live, .redraw, .live, .live])
        XCTAssertTrue(host.frames.last?.pixelBuffer === raw)
        XCTAssertNil(host.frames.last?.compareWith)
        pacer.drawableReturned(kind: .live, captureHostTimeNs: 316, presentedAt: 4.0)
        XCTAssertEqual(host.presented, [100, 300, 316])
        XCTAssertTrue(host.drops.isEmpty, "the waiting frame was shown as the raw frame, not dropped")
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

    /// One drawable in flight with the usual pool of three: the compositor may still hold the drawable shown before
    /// the current one, so asking for a second could block the main thread in nextDrawable().
    @MainActor
    func testOneDrawableInFlightWithThePoolOfThree() throws {
        let host = FakeDrawing()
        let pacer = FramePacer()
        pacer.host = host
        pacer.now = { 10 }
        pacer.drawableSize = CGSize(width: 800, height: 600)
        pacer.present(try frame(1))
        pacer.present(try frame(2))
        XCTAssertEqual(pacer.cap, 1)
        XCTAssertEqual(pacer.inFlight, 1)
        XCTAssertEqual(host.kinds, [.live], "no second drawable while one is in flight")
        XCTAssertTrue(host.drops.isEmpty, "waiting for a drawable is not a drop")
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
        XCTAssertEqual(pacer.inFlight, 1)

        pacer.drawableSize = CGSize(width: 1600, height: 1200)
        XCTAssertEqual(host.kinds, [.live], "no second drawable while one is in flight")
        XCTAssertTrue(host.drops.isEmpty, "a waiting redraw is not a dropped frame")

        pacer.drawableReturned(kind: .live, captureHostTimeNs: 1, presentedAt: 1.0)
        XCTAssertEqual(host.kinds, [.live, .redraw])
        XCTAssertEqual(host.renders.last?.captureHostTimeNs, 1)
        XCTAssertEqual(pacer.inFlight, 1)

        pacer.drawableReturned(kind: .redraw, captureHostTimeNs: 1, presentedAt: 1.1)
        XCTAssertEqual(host.kinds.count, 2, "the redraw ran once")
        XCTAssertEqual(host.presented, [1])
    }

    /// A live frame that arrives while a redraw waits takes its place: it is drawn at the new size anyway.
    @MainActor
    func testLiveFrameSupersedesAQueuedRedraw() throws {
        let host = FakeDrawing()
        let pacer = FramePacer()
        pacer.host = host
        pacer.now = { 10 }
        pacer.drawableSize = CGSize(width: 800, height: 600)
        pacer.present(try frame(1))
        pacer.drawableSize = CGSize(width: 1600, height: 1200)   // the redraw waits: one in flight
        pacer.present(try frame(2))
        XCTAssertEqual(pacer.pending, .live)
        pacer.drawableReturned(kind: .live, captureHostTimeNs: 1, presentedAt: 1.0)
        XCTAssertEqual(host.kinds, [.live, .live], "frame 2 is drawn live at the new size; the redraw never runs")
        pacer.drawableReturned(kind: .live, captureHostTimeNs: 2, presentedAt: 1.1)
        XCTAssertEqual(host.kinds.count, 2)
        XCTAssertEqual(host.presented, [1, 2])
    }

    /// A live frame is dropped as backlog only when a newer one replaces it while it waits, and a discarded live
    /// drawable is a drop, never a display; a discarded redraw is neither.
    @MainActor
    func testLiveFramesKeepTheirDropAccounting() throws {
        let host = FakeDrawing()
        let pacer = FramePacer()
        pacer.host = host
        pacer.now = { 10 }
        pacer.drawableSize = CGSize(width: 800, height: 600)
        pacer.present(try frame(1))
        pacer.present(try frame(2))                              // waits behind frame 1
        XCTAssertTrue(host.drops.isEmpty, "a frame waiting for a drawable is not dropped")
        pacer.present(try frame(3))                              // replaces frame 2 before it was drawn
        XCTAssertEqual(host.drops, [.backlog])
        pacer.drawableReturned(kind: .live, captureHostTimeNs: 1, presentedAt: 0)
        XCTAssertEqual(host.drops, [.backlog, .notPresented])
        XCTAssertTrue(host.presented.isEmpty)
        XCTAssertEqual(host.renders.map(\.captureHostTimeNs), [1, 3], "frame 2 is never drawn")

        pacer.drawableReturned(kind: .live, captureHostTimeNs: 3, presentedAt: 1.1)
        pacer.drawableSize = CGSize(width: 1600, height: 1200)  // a redraw of frame 3
        XCTAssertEqual(host.kinds, [.live, .live, .redraw])
        pacer.drawableReturned(kind: .redraw, captureHostTimeNs: 3, presentedAt: 0)
        XCTAssertEqual(host.drops, [.backlog, .notPresented], "a discarded redraw is not a dropped frame")
        XCTAssertEqual(host.presented, [3])
        XCTAssertEqual(pacer.inFlight, 0)
    }

    /// The frame waited only because the presented handler of the drawable ahead reached the main actor after it:
    /// that drawable was already on screen when the frame arrived. The frame is drawn at once, as live, counted as
    /// displayed with its real latency, and never dropped.
    @MainActor
    func testFrameThatWaitedForALateHandlerIsDrawnAtOnce() throws {
        let host = FakeDrawing()
        let pacer = FramePacer()
        pacer.host = host
        var clock = 10.000
        pacer.now = { clock }
        let timers = Timers()
        timers.install(on: pacer)
        pacer.drawableSize = CGSize(width: 800, height: 600)
        pacer.present(try frame(1))
        clock = 10.020
        pacer.present(try frame(2))
        XCTAssertEqual(host.kinds, [.live])

        clock = 10.021
        pacer.drawableReturned(kind: .live, captureHostTimeNs: 1, presentedAt: 10.0167)
        XCTAssertEqual(host.kinds, [.live, .live], "drawn as the live frame it is, at once")
        XCTAssertEqual(host.renders.last?.captureHostTimeNs, 2)
        XCTAssertEqual(timers.count, 0, "nothing held back")

        pacer.drawableReturned(kind: .live, captureHostTimeNs: 2, presentedAt: 10.0333)
        XCTAssertEqual(host.presented, [1, 2], "counted as displayed")
        XCTAssertEqual(host.presentedAt.last, 10.0333, "its latency is measured at the time it was really shown")
        XCTAssertTrue(host.drops.isEmpty)
        XCTAssertEqual(pacer.inFlight, 0)
    }

    /// The frame waited through a refresh: the drawable ahead was shown after it arrived, so the queue is one refresh
    /// deeper than it needs to be. The frame is held back with the drawable free; the next frame replaces it (one
    /// backlog drop) and is drawn at once into the empty queue, and the scheduled late draw then does nothing.
    @MainActor
    func testLateFrameIsHeldBackAndTheNextFrameTakesItsPlace() throws {
        let host = FakeDrawing()
        let pacer = FramePacer()
        pacer.host = host
        var clock = 10.000
        pacer.now = { clock }
        let timers = Timers()
        timers.install(on: pacer)
        pacer.drawableSize = CGSize(width: 800, height: 600)
        pacer.present(try frame(1))
        clock = 10.005
        pacer.present(try frame(2))

        clock = 10.017
        pacer.drawableReturned(kind: .live, captureHostTimeNs: 1, presentedAt: 10.0167)
        XCTAssertEqual(host.kinds, [.live], "held back, not drawn behind a refresh of delay")
        XCTAssertEqual(pacer.inFlight, 0, "the drawable is free for the next frame")
        XCTAssertEqual(timers.delays, [FramePacer.lateFrameGrace])
        XCTAssertTrue(host.drops.isEmpty)

        clock = 10.019
        pacer.present(try frame(3))
        XCTAssertEqual(host.drops, [.backlog], "the late frame is dropped once")
        XCTAssertEqual(host.renders.map(\.captureHostTimeNs), [1, 3], "the newer frame is drawn at once")
        timers.fireAll()
        XCTAssertEqual(host.kinds.count, 2, "the scheduled late draw does nothing")

        pacer.drawableReturned(kind: .live, captureHostTimeNs: 3, presentedAt: 10.0333)
        XCTAssertEqual(host.presented, [1, 3])
        XCTAssertEqual(pacer.inFlight, 0)
    }

    /// The same late frame when the source then goes still: no newer frame comes, so the late frame is drawn when
    /// the grace runs out, as live, and counted as displayed. The newest picture always reaches the screen.
    @MainActor
    func testLateFrameIsDrawnWhenNoNewerFrameComes() throws {
        let host = FakeDrawing()
        let pacer = FramePacer()
        pacer.host = host
        var clock = 10.000
        pacer.now = { clock }
        let timers = Timers()
        timers.install(on: pacer)
        pacer.drawableSize = CGSize(width: 800, height: 600)
        pacer.present(try frame(1))
        clock = 10.005
        pacer.present(try frame(2))
        clock = 10.017
        pacer.drawableReturned(kind: .live, captureHostTimeNs: 1, presentedAt: 10.0167)
        XCTAssertEqual(host.kinds, [.live])

        clock = 10.034
        timers.fireAll()
        XCTAssertEqual(host.kinds, [.live, .live])
        XCTAssertEqual(host.renders.last?.captureHostTimeNs, 2)
        pacer.drawableReturned(kind: .live, captureHostTimeNs: 2, presentedAt: 10.05)
        XCTAssertEqual(host.presented, [1, 2])
        XCTAssertTrue(host.drops.isEmpty)
        XCTAssertNil(pacer.pending)
    }

    /// A resize or a reveal while a late frame is held back draws it at once, as live, once; the scheduled late draw
    /// then does nothing and the next drawable return draws nothing more.
    @MainActor
    func testRedrawWhileALateFrameIsHeldBackDrawsItLiveOnce() throws {
        let host = FakeDrawing()
        let pacer = FramePacer()
        pacer.host = host
        var clock = 10.000
        pacer.now = { clock }
        let timers = Timers()
        timers.install(on: pacer)
        pacer.drawableSize = CGSize(width: 800, height: 600)
        pacer.present(try frame(1))
        clock = 10.005
        pacer.present(try frame(2))
        clock = 10.017
        pacer.drawableReturned(kind: .live, captureHostTimeNs: 1, presentedAt: 10.0167)

        pacer.drawableSize = CGSize(width: 1600, height: 1200)
        XCTAssertEqual(host.kinds, [.live, .live], "drawn live at the new size, not as an uncounted redraw")
        XCTAssertEqual(host.renders.last?.captureHostTimeNs, 2)
        timers.fireAll()
        pacer.drawableReturned(kind: .live, captureHostTimeNs: 2, presentedAt: 10.0333)
        XCTAssertEqual(host.kinds.count, 2, "drawn once")
        XCTAssertEqual(host.presented, [1, 2])
        XCTAssertTrue(host.drops.isEmpty)
    }

    /// The drawable changes size while a live frame waits behind the one in flight. The frame stays live: it is
    /// drawn once, at the new size, and counted as displayed; no redraw takes its slot.
    @MainActor
    func testResizeWhileALiveFrameWaitsKeepsItLive() throws {
        let host = FakeDrawing()
        let pacer = FramePacer()
        pacer.host = host
        pacer.now = { 10 }
        pacer.drawableSize = CGSize(width: 800, height: 600)
        pacer.present(try frame(1))
        pacer.present(try frame(2))
        pacer.drawableSize = CGSize(width: 1600, height: 1200)
        XCTAssertEqual(host.kinds, [.live])

        pacer.drawableReturned(kind: .live, captureHostTimeNs: 1, presentedAt: 1.0)
        XCTAssertEqual(host.kinds, [.live, .live])
        XCTAssertEqual(host.renders.last?.captureHostTimeNs, 2)
        pacer.drawableReturned(kind: .live, captureHostTimeNs: 2, presentedAt: 1.1)
        XCTAssertEqual(host.kinds.count, 2, "nothing else drawn")
        XCTAssertEqual(host.presented, [1, 2])
        XCTAssertTrue(host.drops.isEmpty)
    }

    /// Frames that keep starving at one drawable in flight (each waits through a refresh, or is replaced while it
    /// waits) mean the display keeps every drawable longer than a refresh: the cap rises by one. Waits caused only
    /// by a presented handler that reaches the main actor after the next frame never raise it, and the cap never
    /// goes past the pool minus one.
    @MainActor
    func testCapRisesOnlyWhenFramesKeepStarving() throws {
        for pool in [3, 2] {
            let host = FakeDrawing()
            host.drawableCount = pool
            let pacer = FramePacer()
            pacer.host = host
            var clock = 10.0
            pacer.now = { clock }
            let timers = Timers()
            timers.install(on: pacer)
            pacer.drawableSize = CGSize(width: 800, height: 600)
            var ns: UInt64 = 1
            pacer.present(try frame(ns))
            var shownNs = ns

            for _ in 0..<20 {
                clock += 0.010
                ns += 1
                pacer.present(try frame(ns))                       // waits behind the one in flight
                pacer.drawableReturned(kind: .live, captureHostTimeNs: shownNs, presentedAt: clock - 0.005)
                shownNs = ns                                       // drawn at once
            }
            XCTAssertEqual(pacer.cap, 1, "handler lag alone is not starvation (pool \(pool))")
            XCTAssertTrue(host.drops.isEmpty)

            for _ in 0..<FramePacer.starvedReturnsBeforeRaise {
                clock += 0.002
                ns += 1
                pacer.present(try frame(ns))                       // waits behind the one in flight
                clock += 0.015
                pacer.drawableReturned(kind: .live, captureHostTimeNs: shownNs, presentedAt: clock - 0.0005)
                clock += 0.002
                ns += 1
                pacer.present(try frame(ns))                       // replaces the held-back late frame
                shownNs = ns
            }
            XCTAssertEqual(pacer.cap, min(2, pool - 1), "pool \(pool)")
            XCTAssertEqual(host.drops.count, FramePacer.starvedReturnsBeforeRaise, "one late frame dropped per return")
        }
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
        XCTAssertEqual(host.renders.map(\.captureHostTimeNs), [1, 3])
        XCTAssertEqual(host.drops, [.backlog], "frame 2 never reached the screen")
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

    /// Releasing the held frame (the share stopped) leaves nothing to redraw, and cancels a late draw.
    @MainActor
    func testReleaseLeavesNothingToRedraw() throws {
        let host = FakeDrawing()
        let pacer = FramePacer()
        pacer.host = host
        var clock = 10.000
        pacer.now = { clock }
        let timers = Timers()
        timers.install(on: pacer)
        pacer.drawableSize = CGSize(width: 800, height: 600)
        pacer.present(try frame(1))
        clock = 10.005
        pacer.present(try frame(2))
        clock = 10.017
        pacer.drawableReturned(kind: .live, captureHostTimeNs: 1, presentedAt: 10.0167)  // frame 2 held back
        pacer.releaseHeldFrame()
        XCTAssertNil(pacer.held)
        XCTAssertNil(pacer.pending)
        timers.fireAll()
        pacer.drawableSize = CGSize(width: 1600, height: 1200)
        pacer.redraw()
        XCTAssertEqual(host.kinds, [.live])
    }
}

/// The pacer against a simulated display (see `DisplaySim`). Latency is in refreshes: the capture time is the
/// refresh at which the source showed the frame, the presented time the refresh at which the view showed it.
final class FramePacerDisplayTests: XCTestCase {
    /// Undisturbed, a source changing at the display rate is shown one refresh after capture, every frame.
    @MainActor
    func testSteadySourceIsShownOneRefreshAfterCapture() throws {
        let sim = try DisplaySim()
        sim.run(refreshes: 120)
        XCTAssertGreaterThanOrEqual(sim.host.presented.count, 118)
        XCTAssertTrue(sim.host.drops.isEmpty)
        XCTAssertEqual(sim.redraws, 0)
        for l in sim.latencies.map(\.refreshes) { XCTAssertEqual(l, 1, accuracy: 0.001) }
        XCTAssertEqual(sim.pacer.cap, 1)
        sim.assertAccounting()
    }

    /// The presented handler reaches the main actor after the next frame (it hops there through a Task). Frames
    /// then wait for bookkeeping only: each is drawn as soon as the handler lands, still one refresh after capture.
    @MainActor
    func testHandlerLandingAfterTheNextFrameCostsNothing() throws {
        let sim = try DisplaySim(.init(arrivalPhase: 0.002, handlerDelay: 0.004))
        sim.run(refreshes: 120)
        XCTAssertGreaterThanOrEqual(sim.host.presented.count, 118)
        XCTAssertTrue(sim.host.drops.isEmpty)
        for l in sim.latencies.map(\.refreshes) { XCTAssertEqual(l, 1, accuracy: 0.001) }
        XCTAssertEqual(sim.pacer.cap, 1)
        sim.assertAccounting()
    }

    /// Round 4's plateau: three extra frames at once. The old rule kept two drawables queued plus one waiting for as
    /// long as the source changed every refresh (three refreshes, 50 ms at 60 Hz). Now the burst costs three
    /// dropped frames and latency is back to one refresh from the next captured frame on.
    @MainActor
    func testBurstDrainsBackToOneRefresh() throws {
        let sim = try DisplaySim()
        sim.run(refreshes: 60)
        let burstAt = sim.refresh
        sim.burst(3)
        sim.run(refreshes: 60)
        XCTAssertEqual(sim.backlogDrops, 3, "each burst frame is replaced by a newer one before it is drawn")
        XCTAssertEqual(sim.host.drops.count, 3)
        let after = sim.latencies(capturedFromRefresh: burstAt + 1)
        XCTAssertGreaterThanOrEqual(after.count, 58)
        XCTAssertEqual(after.max() ?? 0, 1, accuracy: 0.001, "no plateau after the burst")
        XCTAssertEqual(sim.pacer.cap, 1)
        sim.assertAccounting()
    }

    /// A resize redraw while the source changes every refresh (the window fitted to the pick): the redraw takes one
    /// refresh, the frame that waited behind it is late and replaced, and latency is back to one refresh.
    @MainActor
    func testResizeRedrawDrainsBackToOneRefresh() throws {
        let sim = try DisplaySim()
        sim.run(refreshes: 60)
        let resizeAt = sim.refresh
        sim.pacer.drawableSize = CGSize(width: 1600, height: 1200)
        sim.run(refreshes: 60)
        XCTAssertEqual(sim.redraws, 1, "the resize redraw only")
        XCTAssertEqual(sim.backlogDrops, 1, "the frame that waited behind the redraw")
        let after = sim.latencies(capturedFromRefresh: resizeAt + 2)
        XCTAssertGreaterThanOrEqual(after.count, 57)
        XCTAssertEqual(after.max() ?? 0, 1, accuracy: 0.001)
        sim.assertAccounting()
    }

    /// A 50 ms main-thread stall: the frames loop then hands over a stale frame and the newest one back to back.
    /// The old rule queued both and stayed at two refreshes of latency; now latency is back to one refresh for every
    /// frame captured after the first refresh that follows the stall.
    @MainActor
    func testMainThreadStallRecoversAtTheNextRefresh() throws {
        let sim = try DisplaySim()
        sim.run(refreshes: 60)
        sim.stall(after: 0.001, for: 0.050)
        let stallRefresh = sim.refresh
        sim.run(refreshes: 60)
        XCTAssertEqual(sim.lost, 1, "the frame between the first and the newest never reaches the pacer")
        // The stall ends just after refresh stallRefresh + 3; the frame captured at the next refresh is on time.
        let after = sim.latencies(capturedFromRefresh: stallRefresh + 4)
        XCTAssertGreaterThanOrEqual(after.count, 55)
        XCTAssertEqual(after.max() ?? 0, 1, accuracy: 0.001, "no plateau after the stall")
        XCTAssertLessThanOrEqual(sim.host.drops.count, 1)
        sim.assertAccounting()
    }

    /// The source goes still right after a burst: its last frame is late, held back, and drawn when no newer frame
    /// comes. It reaches the screen, counted as displayed once, and nothing is left waiting.
    @MainActor
    func testSourceGoingStillAfterABurstShowsItsLastFrame() throws {
        let sim = try DisplaySim()
        sim.run(refreshes: 60)
        sim.burst(2)
        sim.stopSource()
        sim.run(refreshes: 10)
        XCTAssertEqual(sim.host.presented.last, sim.lastDelivered, "the newest captured frame is on screen")
        XCTAssertEqual(sim.pacer.held?.captureHostTimeNs, sim.lastDelivered)
        XCTAssertNil(sim.pacer.pending)
        XCTAssertEqual(sim.pacer.inFlight, 0)
        XCTAssertEqual(sim.host.drops, [.backlog], "only the burst frame its successor replaced")
        sim.assertAccounting()
    }

    /// A compositor that keeps every drawable one refresh more (each is shown two refreshes after its commit). At
    /// one drawable in flight only every other frame could be shown, so after a few starved returns the cap rises
    /// to two; from then on every frame is shown, two refreshes after capture, and none is dropped.
    @MainActor
    func testDeepCompositorRaisesTheCapAndShowsEveryFrame() throws {
        for handlerDelay in [0.0005, 0.004] {
            let sim = try DisplaySim(.init(depth: 2, handlerDelay: handlerDelay))
            sim.run(refreshes: 40)
            XCTAssertEqual(sim.pacer.cap, 2, "handler delay \(handlerDelay)")
            let warmUpDrops = sim.host.drops.count
            XCTAssertLessThanOrEqual(warmUpDrops, FramePacer.starvedReturnsBeforeRaise + 1)
            let steadyFrom = sim.refresh
            sim.run(refreshes: 120)
            XCTAssertEqual(sim.host.drops.count, warmUpDrops, "no drop once the cap fits the compositor")
            let steady = sim.latencies(capturedFromRefresh: steadyFrom)
            XCTAssertGreaterThanOrEqual(steady.count, 117)
            for l in steady { XCTAssertEqual(l, 2, accuracy: 0.001) }
            sim.assertAccounting()
        }
    }

    /// The deep compositor after a burst: back to two refreshes, the compositor's own delay, not three.
    @MainActor
    func testDeepCompositorBurstDrainsBackToTwoRefreshes() throws {
        let sim = try DisplaySim(.init(depth: 2))
        sim.run(refreshes: 60)
        XCTAssertEqual(sim.pacer.cap, 2)
        let dropsBefore = sim.host.drops.count
        let burstAt = sim.refresh
        sim.burst(2)
        sim.run(refreshes: 60)
        XCTAssertLessThanOrEqual(sim.host.drops.count - dropsBefore, 2)
        let after = sim.latencies(capturedFromRefresh: burstAt + 1)
        XCTAssertGreaterThanOrEqual(after.count, 58)
        XCTAssertEqual(after.max() ?? 0, 2, accuracy: 0.001, "no plateau after the burst")
        sim.assertAccounting()
    }

    /// A 120 Hz panel with the capture at 60 fps (a new frame every other refresh): nothing waits, nothing drops,
    /// and latency is the compositor's own delay in 120 Hz refreshes, with one drawable in flight.
    @MainActor
    func testFastPanelWithASixtyFpsSourceNeedsNoQueue() throws {
        for depth in [1, 2] {
            let sim = try DisplaySim(.init(period: 1.0 / 120, depth: depth, sourceEvery: 2))
            sim.run(refreshes: 240)
            XCTAssertGreaterThanOrEqual(sim.host.presented.count, 118, "depth \(depth)")
            XCTAssertTrue(sim.host.drops.isEmpty, "depth \(depth)")
            for l in sim.latencies.map(\.refreshes) { XCTAssertEqual(l, Double(depth), accuracy: 0.001) }
            XCTAssertEqual(sim.pacer.cap, 1)
            sim.assertAccounting()
        }
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

    /// The sink hands the comparison to the view with the frame, so the frame kept for redraws keeps it too.
    @MainActor
    func testSinkHandsTheComparisonToTheView() throws {
        let sink = FrameSink()
        let view = VideoView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        sink.view = view
        let raw = try makeBuffer()
        sink.push(try makeBuffer(), captureHostTimeNs: 7, compareWith: raw, dividerAt: 0.25)
        XCTAssertTrue(view.pacer.held?.compareWith === raw)
        XCTAssertEqual(view.pacer.held?.divider, 0.25)
        sink.push(try makeBuffer(), captureHostTimeNs: 8)
        XCTAssertNil(view.pacer.held?.compareWith, "a frame pushed without a raw frame is shown alone")
    }

    /// The sink moves the divider on the frame the view keeps, and ends the comparison with the raw frame alone.
    @MainActor
    func testSinkMovesTheDividerAndEndsTheComparison() throws {
        let sink = FrameSink()
        let view = VideoView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        sink.view = view
        let raw = try makeBuffer()
        sink.push(try makeBuffer(), captureHostTimeNs: 7, compareWith: raw, dividerAt: 0.25)
        sink.moveDivider(to: 0.8)
        XCTAssertEqual(view.pacer.held?.divider, 0.8)
        XCTAssertTrue(view.pacer.held?.compareWith === raw)
        let newest = try makeBuffer()
        sink.endComparison(showing: newest, captureHostTimeNs: 9)
        XCTAssertTrue(view.pacer.held?.pixelBuffer === newest)
        XCTAssertEqual(view.pacer.held?.captureHostTimeNs, 9)
        XCTAssertNil(view.pacer.held?.compareWith)
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
