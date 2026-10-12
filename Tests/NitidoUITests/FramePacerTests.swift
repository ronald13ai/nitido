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
    /// A 120 Hz panel, as on the Mac the pacer was first tuned on: one drawable in flight to start.
    var refreshRate: Double = 120
    var renderResult: VideoView.Drop?
    /// The time a render is committed at. The display simulation sets it; unit tests leave it at 0.
    var clock: () -> Double = { 0 }
    private(set) var renders: [(kind: FramePacer.Kind, captureHostTimeNs: UInt64, committedAt: Double)] = []
    private(set) var presented: [UInt64] = []
    /// The presented time of each entry of `presented`, for the latency it reports.
    private(set) var presentedAt: [Double] = []
    private(set) var drops: [VideoView.Drop] = []
    /// Every drawable reported shown, a redraw included, with its presented time.
    private(set) var shown: [(kind: FramePacer.Kind, at: Double)] = []

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
    func frameShown(kind: FramePacer.Kind, at presentedAt: Double) { shown.append((kind, presentedAt)) }
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
///   as ScreenCaptureKit's display time does, and reaches the main actor `arrivalPhase` after it. With `sourcePeriod`
///   it changes every `sourcePeriod` seconds instead, whatever the display does (the viewer's frames come from the
///   other Mac's capture), and each frame carries the moment it changed.
/// - With `refreshRate`, the view reports that rate to the pacer, as `VideoView` does for its window's screen.
///   Without it the pacer is never told and keeps one drawable in flight to start, as on a panel at twice the capture
///   rate or faster: the tests that leave it out at a 60 Hz period exercise the one-in-flight rules (a late frame held
///   back, a burst drained) on a compositor that shows a drawable at the next refresh. On a real 60 Hz panel the pacer
///   starts at two (`testSixtyHertzPanelShowsAFiftyEightFpsSourceWithTwoInFlightFromTheStart`).
/// - Main-actor work (arrivals, presented handlers, the pacer's late draws, divider moves) waits while the main
///   thread is stalled. Of the frames that arrive during a stall, the first (already handed to the waiting frames
///   loop) and the newest (the capture stream keeps one buffered) reach the pacer; the ones between are lost before
///   it sees them.
/// - With `compare`, every frame carries a raw frame to compare against, split at the divider current when it
///   arrives, as the codec loop's decoded frames do (`ShareModel.handleDecoded` pushes each with `dividerPosition`).
@MainActor
private final class DisplaySim {
    struct Config {
        var period = 1.0 / 60
        var depth = 1
        var arrivalPhase = 0.002
        var handlerDelay = 0.0005
        var sourceEvery = 1
        var compare = false
        /// Added to `arrivalPhase` frame by frame, in turn: frames that reach the main actor a little late.
        var arrivalJitter: [Double] = [0]
        /// A source that changes every this many seconds, on its own clock, in place of `sourceEvery`.
        var sourcePeriod: Double? = nil
        /// The refresh rate the view reports to the pacer; nil reports none, and the pacer keeps its first cap.
        var refreshRate: Double? = nil
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
    private let raw: CVPixelBuffer
    /// Whether the next frame carries a raw frame to compare against: `compare`, until `endComparison`.
    private lazy var comparing = config.compare
    /// The divider the next frame carries; `drag` moves it.
    private(set) var divider: CGFloat = 0.5
    /// Frames the source has sent, for `arrivalJitter`.
    private var sourceFrames = 0
    /// Main-actor time.
    private(set) var clock: Double = 1
    /// The last refresh run.
    private(set) var refresh = 0
    private var sourceStopsAfter = Int.max
    /// The next change of a source with `sourcePeriod`.
    private var nextSourceChange: Double = 1
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
        raw = try makeBuffer()
        pacer.host = host
        pacer.now = { [unowned self] in clock }
        pacer.schedule = { [unowned self] delay, action in add(at: clock + delay, arrival: false, action) }
        host.clock = { [unowned self] in clock }
        if let rate = config.refreshRate {
            host.refreshRate = rate
            pacer.displayChanged()
        }
        pacer.drawableSize = CGSize(width: 800, height: 600)
    }

    func time(ofRefresh j: Int) -> Double { 1 + Double(j) * config.period }

    /// Runs `count` more refreshes and the main-actor work between them.
    func run(refreshes count: Int) {
        let last = refresh + count
        if let period = config.sourcePeriod {
            while nextSourceChange <= time(ofRefresh: last) {
                let jitter = config.arrivalJitter[sourceFrames % config.arrivalJitter.count]
                sourceFrames += 1
                scheduleArrival(at: nextSourceChange + config.arrivalPhase + jitter, capturedAt: nextSourceChange)
                nextSourceChange += period
            }
        }
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
    func stopSource() {
        precondition(config.sourcePeriod == nil, "a source on its own clock runs on")
        sourceStopsAfter = refresh
    }

    /// The divider is dragged: `count` moves `interval` apart, the first `delay` from now, each to a new position.
    /// A move is main-actor work (the gesture sets `ShareModel.dividerPosition`, which moves the view's divider).
    func drag(moves count: Int, every interval: Double, after delay: Double = 0.003) {
        let start = clock + delay
        for i in 0..<count {
            add(at: start + Double(i) * interval, arrival: false) { [unowned self] in
                divider = 0.2 + 0.6 * CGFloat(i + 1) / CGFloat(count)
                pacer.moveDivider(to: divider)
            }
        }
    }

    /// The codec loop is turned off `delay` from now (main-actor work): the newest frame, raw, takes the held
    /// comparison's place (`FrameSink.endComparison`), and the frames after it come without a raw frame to compare.
    func endComparison(after delay: Double) {
        add(at: clock + delay, arrival: false) { [unowned self] in
            comparing = false
            pacer.replaceHeld(with: FramePacer.Frame(pixelBuffer: buffer, captureHostTimeNs: delivered.last ?? 0))
        }
    }

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
            pacer.present(FramePacer.Frame(pixelBuffer: buffer, captureHostTimeNs: ns,
                                           compareWith: comparing ? raw : nil, divider: divider))
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
        if config.sourcePeriod == nil, refresh % config.sourceEvery == 0, refresh <= sourceStopsAfter {
            let jitter = config.arrivalJitter[sourceFrames % config.arrivalJitter.count]
            sourceFrames += 1
            scheduleArrival(at: t + config.arrivalPhase + jitter, capturedAt: t)
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

    /// A still source sends no frame to carry a divider move, so the held comparison is drawn again with the new
    /// divider, as a redraw (not a displayed frame), once the next frame is overdue: half a capture interval after it
    /// was due. Moves until then ride on that one redraw. The same divider, or a frame without a comparison, schedules
    /// nothing.
    @MainActor
    func testMovingTheDividerRedrawsTheHeldComparisonOnceNoFrameCarriesIt() throws {
        let host = FakeDrawing()
        let pacer = FramePacer()
        pacer.host = host
        var clock = 10.000
        pacer.now = { clock }
        let timers = Timers()
        timers.install(on: pacer)
        let interval = FramePacer.lateFrameGrace
        pacer.drawableSize = CGSize(width: 1440, height: 900)
        let raw = try makeBuffer()
        pacer.present(FramePacer.Frame(pixelBuffer: try makeBuffer(), captureHostTimeNs: 100, compareWith: raw, divider: 0.5))
        clock = 10.017
        pacer.drawableReturned(kind: .live, captureHostTimeNs: 100, presentedAt: 10.0167)
        clock = 10.020
        pacer.moveDivider(to: 0.3)
        clock = 10.022
        pacer.moveDivider(to: 0.2)
        XCTAssertEqual(host.kinds, [.live], "nothing drawn while the next frame may still carry the move")
        XCTAssertEqual(pacer.held?.divider, 0.2, "the held frame splits at the newest divider at once")
        XCTAssertEqual(timers.count, 1, "moves until the redraw ride on one")
        XCTAssertEqual(timers.delays.last ?? 0, 10.000 + 1.5 * interval - 10.020, accuracy: 1e-9,
                       "half a capture interval after the next frame was due")

        clock = 10.025
        timers.fireAll()
        XCTAssertEqual(host.kinds, [.live, .redraw])
        XCTAssertTrue(host.frames.last?.compareWith === raw)
        XCTAssertEqual(host.frames.last?.divider, 0.2)
        pacer.drawableReturned(kind: .redraw, captureHostTimeNs: 100, presentedAt: 10.0333)
        XCTAssertEqual(host.presented, [100], "a divider move is not a displayed frame")

        clock = 10.040
        pacer.moveDivider(to: 0.2)
        XCTAssertEqual(timers.count, 0, "the same divider schedules nothing")
        pacer.moveDivider(to: 0.4)
        XCTAssertEqual(timers.count, 1)
        XCTAssertEqual(timers.delays.last ?? 0, 10.000 + 2.5 * interval - 10.040, accuracy: 1e-9,
                       "the middle of the next capture interval in which no frame came")
        clock = 10.042
        timers.fireAll()
        XCTAssertEqual(host.kinds, [.live, .redraw, .redraw])
        XCTAssertEqual(host.frames.last?.divider, 0.4)
        pacer.drawableReturned(kind: .redraw, captureHostTimeNs: 100, presentedAt: 10.05)

        clock = 10.060
        pacer.present(try frame(200))
        pacer.drawableReturned(kind: .live, captureHostTimeNs: 200, presentedAt: 10.0667)
        pacer.moveDivider(to: 0.7)
        XCTAssertEqual(timers.count, 0, "a frame without a comparison is not drawn again")
        XCTAssertNil(pacer.held?.compareWith)
        XCTAssertTrue(host.drops.isEmpty)
    }

    /// A moving source carries a divider move on its next frame (the model pushes every decoded frame with the current
    /// divider), so the scheduled redraw does nothing once that frame came; a frame already waiting for a drawable is
    /// drawn with the new divider and nothing is scheduled. A redraw there would take the drawable from the next frame,
    /// which would wait behind it, be late and be dropped: a frame lost per move.
    @MainActor
    func testDividerMovesRideOnTheNextFrameOrTheOneWaiting() throws {
        let host = FakeDrawing()
        let pacer = FramePacer()
        pacer.host = host
        var clock = 10.000
        pacer.now = { clock }
        let timers = Timers()
        timers.install(on: pacer)
        pacer.drawableSize = CGSize(width: 1440, height: 900)
        let raw = try makeBuffer()
        pacer.present(FramePacer.Frame(pixelBuffer: try makeBuffer(), captureHostTimeNs: 100, compareWith: raw, divider: 0.5))
        clock = 10.003
        pacer.moveDivider(to: 0.4)
        XCTAssertEqual(timers.count, 1)
        clock = 10.017
        pacer.drawableReturned(kind: .live, captureHostTimeNs: 100, presentedAt: 10.0167)
        clock = 10.018
        pacer.present(FramePacer.Frame(pixelBuffer: try makeBuffer(), captureHostTimeNs: 116, compareWith: raw, divider: 0.4))
        timers.fireAll()
        XCTAssertEqual(host.kinds, [.live, .live], "the new frame carried the move: no redraw")
        XCTAssertEqual(host.frames.last?.divider, 0.4)

        clock = 10.034
        pacer.present(FramePacer.Frame(pixelBuffer: try makeBuffer(), captureHostTimeNs: 133, compareWith: raw, divider: 0.4))
        XCTAssertEqual(pacer.pending, .live, "waits for the drawable of frame 116")
        pacer.moveDivider(to: 0.6)
        XCTAssertEqual(timers.count, 0, "the waiting frame carries the move: nothing scheduled")
        clock = 10.0345
        pacer.drawableReturned(kind: .live, captureHostTimeNs: 116, presentedAt: 10.0333)
        XCTAssertEqual(host.kinds, [.live, .live, .live], "no redraw at all")
        XCTAssertEqual(host.renders.last?.captureHostTimeNs, 133)
        XCTAssertEqual(host.frames.last?.divider, 0.6)
        XCTAssertTrue(host.drops.isEmpty)
    }

    /// On a still source, moves made while the redraw waits at the frames-in-flight cap ride on it: it is drawn once,
    /// with the last divider, when the drawable comes back.
    @MainActor
    func testDividerMovesAtTheCapAreDrawnOnceWithTheLastDivider() throws {
        let host = FakeDrawing()
        let pacer = FramePacer()
        pacer.host = host
        var clock = 10.000
        pacer.now = { clock }
        let timers = Timers()
        timers.install(on: pacer)
        pacer.drawableSize = CGSize(width: 1440, height: 900)
        pacer.present(FramePacer.Frame(pixelBuffer: try makeBuffer(), captureHostTimeNs: 100, compareWith: try makeBuffer(), divider: 0.5))
        clock = 10.003
        pacer.moveDivider(to: 0.4)
        pacer.moveDivider(to: 0.6)
        XCTAssertEqual(timers.count, 1)
        clock = 10.025
        timers.fireAll()
        XCTAssertEqual(host.kinds, [.live], "one drawable in flight: the redraw waits")
        XCTAssertEqual(pacer.pending, .redraw)
        pacer.moveDivider(to: 0.7)
        XCTAssertEqual(timers.count, 0, "the waiting redraw carries the move")
        clock = 10.034
        pacer.drawableReturned(kind: .live, captureHostTimeNs: 100, presentedAt: 10.0333)
        XCTAssertEqual(host.kinds, [.live, .redraw])
        XCTAssertEqual(host.frames.last?.divider, 0.7)
        pacer.drawableReturned(kind: .redraw, captureHostTimeNs: 100, presentedAt: 10.05)
        timers.fireAll()
        XCTAssertEqual(host.kinds.count, 2, "drawn once")
    }

    /// The loop turned off: the raw frame takes the held comparison's place at once. A still source sends no frame to
    /// show it, so it is drawn alone, as a redraw, once the next frame is overdue (a moving source's next frame shows it
    /// first: `testTurningTheLoopOffOverAMovingSourceCostsNoFrame`). A decoded frame still waiting for a drawable is
    /// drawn as the raw frame instead, once, and counted as displayed, and nothing is scheduled.
    @MainActor
    func testReplacingTheHeldFrameDrawsTheRawFrameAlone() throws {
        let host = FakeDrawing()
        let pacer = FramePacer()
        pacer.host = host
        var clock = 10.000
        pacer.now = { clock }
        let timers = Timers()
        timers.install(on: pacer)
        pacer.drawableSize = CGSize(width: 1440, height: 900)
        pacer.present(FramePacer.Frame(pixelBuffer: try makeBuffer(), captureHostTimeNs: 100, compareWith: try makeBuffer(), divider: 0.5))
        clock = 10.017
        pacer.drawableReturned(kind: .live, captureHostTimeNs: 100, presentedAt: 10.0167)
        clock = 10.020
        let newest = try makeBuffer()
        pacer.replaceHeld(with: FramePacer.Frame(pixelBuffer: newest, captureHostTimeNs: 150))
        XCTAssertTrue(pacer.held?.pixelBuffer === newest, "later redraws show the raw frame")
        XCTAssertEqual(host.kinds, [.live], "nothing drawn while the source's next frame may still show it")
        XCTAssertEqual(timers.count, 1)
        clock = 10.025
        timers.fireAll()
        XCTAssertEqual(host.kinds, [.live, .redraw])
        XCTAssertTrue(host.frames.last?.pixelBuffer === newest)
        XCTAssertNil(host.frames.last?.compareWith)
        clock = 10.034
        pacer.drawableReturned(kind: .redraw, captureHostTimeNs: 150, presentedAt: 10.0333)
        XCTAssertEqual(host.presented, [100])

        clock = 10.100
        pacer.present(FramePacer.Frame(pixelBuffer: try makeBuffer(), captureHostTimeNs: 300, compareWith: try makeBuffer(), divider: 0.5))
        pacer.present(FramePacer.Frame(pixelBuffer: try makeBuffer(), captureHostTimeNs: 316, compareWith: try makeBuffer(), divider: 0.5))
        XCTAssertEqual(pacer.pending, .live, "the second decoded frame waits for a drawable")
        let raw = try makeBuffer()
        pacer.replaceHeld(with: FramePacer.Frame(pixelBuffer: raw, captureHostTimeNs: 316))
        XCTAssertEqual(timers.count, 0, "the waiting frame shows the raw picture")
        clock = 10.110
        pacer.drawableReturned(kind: .live, captureHostTimeNs: 300, presentedAt: 10.0999)
        XCTAssertEqual(host.kinds, [.live, .redraw, .live, .live])
        XCTAssertTrue(host.frames.last?.pixelBuffer === raw)
        XCTAssertNil(host.frames.last?.compareWith)
        clock = 10.120
        pacer.drawableReturned(kind: .live, captureHostTimeNs: 316, presentedAt: 10.1166)
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

    /// Every drawable that reaches the screen is reported shown, a redraw included, and a discarded one is not; only a
    /// captured frame counts as presented. A first frame that came while the window could not draw it reaches the screen
    /// as a redraw, and that is what lifts the picture's cover (spec 11, M6 and M7, amended 2026-10-12).
    @MainActor
    func testAFirstFrameHeldWhileHiddenIsShownByTheRedraw() throws {
        let host = FakeDrawing()
        let pacer = FramePacer()
        pacer.host = host
        pacer.drawableSize = CGSize(width: 800, height: 600)
        host.canShowFrames = false
        pacer.present(try frame(1))
        XCTAssertEqual(host.drops, [.hidden])
        XCTAssertTrue(host.renders.isEmpty)

        host.canShowFrames = true
        pacer.redraw()
        XCTAssertEqual(host.kinds, [.redraw], "the held frame, drawn again as the window shows")
        pacer.drawableReturned(kind: .redraw, captureHostTimeNs: 1, presentedAt: 2.0)
        XCTAssertEqual(host.shown.map(\.kind), [.redraw])
        XCTAssertEqual(host.shown.map(\.at), [2.0])
        XCTAssertTrue(host.presented.isEmpty, "a redraw is not a display")

        pacer.present(try frame(2))
        pacer.drawableReturned(kind: .live, captureHostTimeNs: 2, presentedAt: 0)
        XCTAssertEqual(host.shown.count, 1, "a discarded drawable reached nothing")
        pacer.present(try frame(3))
        pacer.drawableReturned(kind: .live, captureHostTimeNs: 3, presentedAt: 3.0)
        XCTAssertEqual(host.shown.map(\.kind), [.redraw, .live])
        XCTAssertEqual(host.presented, [3], "a captured frame shown is both")
        XCTAssertEqual(host.drops, [.hidden, .notPresented])
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

    /// A raised cap is not for the rest of the session: ten seconds on the pacer's clock without a starved frame lower it
    /// by one again, so a transient (a Space switch, Mission Control, a main-thread hitch) costs a refresh of latency
    /// for ten seconds, not for good. Ten seconds whatever the rate drawables come back at: a 120 Hz panel returns 1,200
    /// in that time, a 30 fps source 300. A cap that has to rise again right after it was lowered waits twice as long
    /// before the next try, so a display that needs the deeper queue is probed rarely.
    @MainActor
    func testCapStepsBackDownAfterTenSecondsWithoutStarving() throws {
        let host = FakeDrawing()
        host.drawableCount = 3
        let pacer = FramePacer()
        pacer.host = host
        var clock = 10.0
        pacer.now = { clock }
        let timers = Timers()
        timers.install(on: pacer)
        pacer.drawableSize = CGSize(width: 800, height: 600)
        let buffer = try makeBuffer()
        var ns: UInt64 = 1
        pacer.present(FramePacer.Frame(pixelBuffer: buffer, captureHostTimeNs: ns))
        var shownNs = ns

        /// Each frame waits through a refresh at the cap, then a newer one replaces it: one starved return each.
        func starve(_ count: Int) {
            for _ in 0..<count {
                clock += 0.002; ns += 1
                pacer.present(FramePacer.Frame(pixelBuffer: buffer, captureHostTimeNs: ns))
                clock += 0.015
                pacer.drawableReturned(kind: .live, captureHostTimeNs: shownNs, presentedAt: clock - 0.0005)
                clock += 0.002; ns += 1
                pacer.present(FramePacer.Frame(pixelBuffer: buffer, captureHostTimeNs: ns))
                shownNs = ns
            }
        }
        /// For `seconds`, a frame every `interval` whose drawable comes back before the next one waited through a
        /// refresh: returns without starving.
        func healthy(for seconds: Double, every interval: Double) {
            let end = clock + seconds
            while clock + interval <= end {
                clock += interval; ns += 1
                pacer.present(FramePacer.Frame(pixelBuffer: buffer, captureHostTimeNs: ns))
                pacer.drawableReturned(kind: .live, captureHostTimeNs: shownNs, presentedAt: clock - 0.005)
                shownNs = ns
            }
        }

        starve(FramePacer.starvedReturnsBeforeRaise)
        XCTAssertEqual(pacer.cap, 2)
        healthy(for: 9.9, every: 1.0 / 120)
        XCTAssertEqual(pacer.cap, 2, "not before ten seconds without starving, however many drawables came back")
        healthy(for: 0.2, every: 1.0 / 120)
        XCTAssertEqual(pacer.cap, 1, "ten seconds without starving lower the cap")

        starve(FramePacer.starvedReturnsBeforeRaise)
        XCTAssertEqual(pacer.cap, 2, "starving again right away raises it again")
        healthy(for: 19.8, every: 1.0 / 30)
        XCTAssertEqual(pacer.cap, 2, "a cap that had to rise right after it was lowered waits twice as long")
        healthy(for: 0.3, every: 1.0 / 30)
        XCTAssertEqual(pacer.cap, 1, "twenty seconds without starving lower it")
        healthy(for: 30, every: 1.0 / 60)
        XCTAssertEqual(pacer.cap, 1, "never below one")
    }

    /// The cap starts from the display the window is on and follows it to another one. Two refreshes are what one
    /// drawable in flight costs a frame (the compositor puts it on the glass at the second refresh after its commit),
    /// so a panel slower than twice the capture rate needs two in flight to show a 60 fps source, and never goes below
    /// two however long it stays calm; a faster one starts from one and keeps the rule that raises it and lowers it
    /// again. A pool of two drawables never allows two in flight, and an unknown rate changes nothing.
    @MainActor
    func testTheCapStartsFromTheDisplayAndFollowsItToAnother() throws {
        let host = FakeDrawing()
        let pacer = FramePacer()
        pacer.host = host
        var clock = 10.0
        pacer.now = { clock }
        let timers = Timers()
        timers.install(on: pacer)
        pacer.drawableSize = CGSize(width: 800, height: 600)
        let buffer = try makeBuffer()
        var ns: UInt64 = 1
        var shownNs = ns
        pacer.present(FramePacer.Frame(pixelBuffer: buffer, captureHostTimeNs: ns))
        /// Frames whose drawables come back in time, for `seconds`: nothing starves.
        func calm(for seconds: Double) {
            let end = clock + seconds
            while clock + 1.0 / 60 <= end {
                clock += 1.0 / 60; ns += 1
                pacer.present(FramePacer.Frame(pixelBuffer: buffer, captureHostTimeNs: ns))
                pacer.drawableReturned(kind: .live, captureHostTimeNs: shownNs, presentedAt: clock - 0.005)
                shownNs = ns
            }
        }

        for (rate, expected) in [(120.0, 1), (60, 2), (59.94, 2), (90, 2), (144, 1), (60, 2)] {
            host.refreshRate = rate
            pacer.displayChanged()
            XCTAssertEqual(pacer.cap, expected, "\(rate) Hz")
        }
        calm(for: 30)
        XCTAssertEqual(pacer.cap, 2, "thirty calm seconds on a 60 Hz panel leave two in flight")
        XCTAssertTrue(host.drops.isEmpty)

        host.refreshRate = 120
        pacer.displayChanged()
        XCTAssertEqual(pacer.cap, 1, "moved to a 120 Hz panel")
        host.refreshRate = 0
        pacer.displayChanged()
        XCTAssertEqual(pacer.cap, 1, "a rate the screen does not say changes nothing")
        host.drawableCount = 2
        host.refreshRate = 60
        pacer.displayChanged()
        XCTAssertEqual(pacer.cap, 1, "a pool of two never has two in flight")
    }

    /// ProMotion runs the panel at 60 Hz for a 60 fps source while the screen still says 120 Hz. The pacer measures the
    /// cadence of the presentations over each second: every one 16.7 ms or a whole multiple of it after the last means
    /// a 60 Hz panel, so two in flight, however long it stays calm, and through a change of the rate the screen says.
    /// Back at 120 Hz (presentations 16.7 or 25 ms apart for a 58 fps source, which only a 120 Hz panel shows) the floor
    /// is the screen's again within a second or so, and the cap steps down to one after ten calm seconds from then, not
    /// before.
    @MainActor
    func testTheCapFollowsThePresentationCadenceUnderTheScreensRate() throws {
        let host = FakeDrawing()
        let pacer = FramePacer()
        pacer.host = host
        var clock = 10.0
        pacer.now = { clock }
        let timers = Timers()
        timers.install(on: pacer)
        pacer.drawableSize = CGSize(width: 800, height: 600)
        pacer.displayChanged()
        XCTAssertEqual(pacer.cap, 1, "the screen says 120 Hz")
        let buffer = try makeBuffer()
        var ns: UInt64 = 0
        var shownNs: UInt64?
        /// A 58 fps source for `seconds`. Each drawable is presented at the last refresh of a `refresh`-second grid
        /// before the next frame arrives and comes back then, so nothing waits and nothing starves. The caps seen on
        /// the way.
        func run(for seconds: Double, refresh: Double) -> Set<Int> {
            var caps: Set<Int> = []
            let end = clock + seconds
            while clock + 1.0 / 58 <= end {
                clock += 1.0 / 58
                if let shown = shownNs {
                    let presentedAt = (clock / refresh).rounded(.down) * refresh
                    pacer.drawableReturned(kind: .live, captureHostTimeNs: shown, presentedAt: presentedAt)
                }
                ns += 1
                pacer.present(FramePacer.Frame(pixelBuffer: buffer, captureHostTimeNs: ns))
                shownNs = ns
                caps.insert(pacer.cap)
            }
            return caps
        }

        _ = run(for: 2, refresh: 1.0 / 60)
        XCTAssertEqual(pacer.cap, 2, "two in flight within two seconds of presentations at 60 Hz")
        XCTAssertEqual(run(for: 30, refresh: 1.0 / 60), [2], "thirty calm seconds at 60 Hz leave two in flight")
        // The screen says another rate (a mode change): the cadence is measured afresh against it, and the two in flight
        // stay meanwhile.
        for rate in [144.0, 120] {
            host.refreshRate = rate
            pacer.displayChanged()
            XCTAssertEqual(run(for: 5, refresh: 1.0 / 60), [2], "\(rate) Hz said, 60 Hz shown")
        }
        XCTAssertEqual(run(for: 10, refresh: 1.0 / 120), [2], "back at 120 Hz: not before ten calm seconds")
        _ = run(for: 2, refresh: 1.0 / 120)
        XCTAssertEqual(pacer.cap, 1, "then one again")
        XCTAssertEqual(run(for: 30, refresh: 1.0 / 120), [1], "and it stays there")
        XCTAssertTrue(host.drops.isEmpty)
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

    /// The two-Mac test's viewer: a 60 Hz panel whose compositor puts each drawable on the glass at the second refresh
    /// after its commit (with one drawable in flight that panel showed 33 fps of a 58 fps source), and a source at
    /// 58 fps, on the sharer's clock. Two in flight from the start: every frame is shown, none waits behind another or
    /// is dropped, and the cap stays at two for 40 seconds, four times the calm that lowered a raised cap, so it never
    /// swings between one and two.
    @MainActor
    func testSixtyHertzPanelShowsAFiftyEightFpsSourceWithTwoInFlightFromTheStart() throws {
        let sim = try DisplaySim(.init(depth: 2, sourcePeriod: 1.0 / 58, refreshRate: 60))
        XCTAssertEqual(sim.pacer.cap, 2, "two in flight before the first frame")
        var caps: Set<Int> = []
        for _ in 0..<40 {
            sim.run(refreshes: 60)
            caps.insert(sim.pacer.cap)
        }
        XCTAssertEqual(caps, [2], "never back to one")
        XCTAssertEqual(sim.backlogDrops, 0, "no frame replaced while it waited")
        XCTAssertTrue(sim.host.drops.isEmpty)
        let shownPerSecond = Double(sim.host.presented.count) / 40
        XCTAssertGreaterThan(shownPerSecond, 57.5, "close to the source's 58 fps")
        let latest = sim.latencies.map(\.refreshes).max() ?? 0
        XCTAssertLessThanOrEqual(latest, 2 + 0.002 * 60 + 0.001, "the compositor's two refreshes after the frame arrived, no more")
        sim.assertAccounting()
    }

    /// The two-Mac test's 60 Hz panel (two in flight from the start, a compositor that puts each drawable on the glass
    /// at the second refresh after its commit) after three extra frames at once, as a network that delivered several
    /// together hands them over: the cap stays at two, the burst costs its three frames (each replaced by a newer one
    /// before it was drawn), and every frame from the burst on is shown two refreshes after capture, the compositor's
    /// own delay, never a refresh more. Measured with the probe for this case: 3 backlog drops, 2.000 refreshes.
    @MainActor
    func testSixtyHertzPanelWithTwoInFlightDrainsABurstBackToTwoRefreshes() throws {
        let sim = try DisplaySim(.init(depth: 2, refreshRate: 60))
        sim.run(refreshes: 60)
        XCTAssertEqual(sim.pacer.cap, 2)
        XCTAssertTrue(sim.host.drops.isEmpty)
        let burstAt = sim.refresh
        sim.burst(3)
        var caps: Set<Int> = []
        for _ in 0..<10 { sim.run(refreshes: 6); caps.insert(sim.pacer.cap) }
        XCTAssertEqual(caps, [2], "never back to one, never up to three")
        XCTAssertEqual(sim.host.drops, [.backlog, .backlog, .backlog], "each burst frame replaced before it was drawn")
        let after = sim.latencies(capturedFromRefresh: burstAt)
        XCTAssertGreaterThanOrEqual(after.count, 59)
        XCTAssertEqual(after.max() ?? 0, 2, accuracy: 0.001, "no plateau after the burst")
        XCTAssertEqual(after.min() ?? 0, 2, accuracy: 0.001)
        sim.assertAccounting()
    }

    /// The same panel after a 50 ms main-thread stall: the frames loop then hands over a stale frame and the newest one
    /// back to back. The cap stays at two; the frame between them never reaches the pacer and the stale one is replaced
    /// by the newest (one backlog drop); the frames the stall caught are shown late (4 and then 3 refreshes after
    /// capture), and every frame captured from the first refresh after the stall on is back at two. Measured with the
    /// probe for this case: 1 lost, 1 backlog drop, latencies 4, 3, then 2.000.
    @MainActor
    func testSixtyHertzPanelWithTwoInFlightRecoversFromAFiftyMillisecondStall() throws {
        let sim = try DisplaySim(.init(depth: 2, refreshRate: 60))
        sim.run(refreshes: 60)
        let stallRefresh = sim.refresh
        sim.stall(after: 0.001, for: 0.050)
        var caps: Set<Int> = []
        for _ in 0..<10 { sim.run(refreshes: 6); caps.insert(sim.pacer.cap) }
        XCTAssertEqual(caps, [2], "never back to one, never up to three")
        XCTAssertEqual(sim.lost, 1, "the frame between the first and the newest never reaches the pacer")
        XCTAssertEqual(sim.host.drops, [.backlog], "the stale frame the newest replaced")
        XCTAssertEqual(sim.latencies(capturedFromRefresh: stallRefresh).max() ?? 0, 4, accuracy: 0.001, "the frame that waited out the stall")
        XCTAssertEqual(sim.latencies(capturedFromRefresh: stallRefresh + 2).max() ?? 0, 3, accuracy: 0.001)
        // The stall ends just after refresh stallRefresh + 3; the frame captured at the next refresh is on time.
        let after = sim.latencies(capturedFromRefresh: stallRefresh + 4)
        XCTAssertGreaterThanOrEqual(after.count, 54)
        XCTAssertEqual(after.max() ?? 0, 2, accuracy: 0.001, "no plateau after the stall")
        XCTAssertEqual(after.min() ?? 0, 2, accuracy: 0.001)
        sim.assertAccounting()
    }

    /// The same panel when the drawable changes size (the window fitted to the pick): the held frame is drawn again
    /// once, the cap stays at two, the frame that waited behind the redraw is replaced by the next (one backlog drop),
    /// and every frame is shown two refreshes after capture, the redraw costing no refresh of latency. Measured with
    /// the probe for this case: 1 redraw, 1 backlog drop, 2.000 refreshes.
    @MainActor
    func testSixtyHertzPanelWithTwoInFlightKeepsTwoRefreshesThroughAResize() throws {
        let sim = try DisplaySim(.init(depth: 2, refreshRate: 60))
        sim.run(refreshes: 60)
        let resizeAt = sim.refresh
        sim.pacer.drawableSize = CGSize(width: 1600, height: 1200)
        var caps: Set<Int> = []
        for _ in 0..<10 { sim.run(refreshes: 6); caps.insert(sim.pacer.cap) }
        XCTAssertEqual(caps, [2], "never back to one, never up to three")
        XCTAssertEqual(sim.redraws, 1, "the resize redraw only")
        XCTAssertEqual(sim.host.drops, [.backlog], "the frame that waited behind the redraw")
        let after = sim.latencies(capturedFromRefresh: resizeAt)
        XCTAssertGreaterThanOrEqual(after.count, 58)
        XCTAssertEqual(after.max() ?? 0, 2, accuracy: 0.001, "no plateau after the resize")
        XCTAssertEqual(after.min() ?? 0, 2, accuracy: 0.001)
        sim.assertAccounting()
    }

    /// The same source and compositor on a 120 Hz panel: two of its refreshes are shorter than a capture interval, so
    /// one drawable in flight shows every frame without adding a refresh of latency, and the pacer keeps one. The
    /// presentations come 16.7 or 25 ms apart, and a 25 ms gap is one only a panel faster than 60 Hz shows, so the
    /// presentation cadence (`FramePacer`) never takes this panel for one at 60 Hz.
    @MainActor
    func testOneTwentyHertzPanelShowsAFiftyEightFpsSourceWithOneInFlight() throws {
        let sim = try DisplaySim(.init(period: 1.0 / 120, depth: 2, sourcePeriod: 1.0 / 58, refreshRate: 120))
        var caps: Set<Int> = []
        for _ in 0..<20 {
            sim.run(refreshes: 120)
            caps.insert(sim.pacer.cap)
        }
        XCTAssertEqual(caps, [1])
        XCTAssertTrue(sim.host.drops.isEmpty)
        XCTAssertGreaterThan(Double(sim.host.presented.count) / 20, 57.5)
        sim.assertAccounting()
    }

    /// The Pro's own window on the second two-Mac test (2026-10-09): ProMotion ran its panel at 60 Hz for the 60 fps
    /// source while the screen still said 120 Hz, so the pacer started at one drawable in flight, starved, rose to two,
    /// stepped back to one after ten calm seconds and starved again, every 20 to 30 s, with bursts of 5 to 15 backlog
    /// drops. A compositor at 60 Hz that shows a drawable at the second refresh after its commit, a 58 fps source and a
    /// screen that says 120 Hz: the cap settles at two within two seconds (the starving rule raises it, the
    /// presentation cadence keeps it there) and stays at two for 40 s, four times the calm that lowered it, with no
    /// frame dropped.
    @MainActor
    func testAPanelPresentingAtSixtyHertzUnderAScreenSayingOneTwentyKeepsTwoInFlight() throws {
        let sim = try DisplaySim(.init(depth: 2, sourcePeriod: 1.0 / 58, refreshRate: 120))
        XCTAssertEqual(sim.pacer.cap, 1, "the screen says 120 Hz")
        sim.run(refreshes: 120)
        XCTAssertEqual(sim.pacer.cap, 2, "two in flight within two seconds")
        let settled = sim.host.drops.count
        let shownBefore = sim.host.presented.count
        var caps: Set<Int> = []
        for _ in 0..<400 {
            sim.run(refreshes: 6)
            caps.insert(sim.pacer.cap)
        }
        XCTAssertEqual(caps, [2], "never back to one")
        XCTAssertEqual(sim.host.drops.count, settled, "no frame dropped once settled: \(Array(sim.host.drops.dropFirst(settled)))")
        XCTAssertGreaterThan(Double(sim.host.presented.count - shownBefore) / 40, 57.5, "close to the source's 58 fps")
        sim.assertAccounting()
    }

    /// A 60 fps source in step with a 120 Hz panel is presented every 16.7 ms too, which the pacer cannot tell from a
    /// panel at 60 Hz, so it keeps two in flight. That costs nothing here: each drawable comes back before the next
    /// frame arrives, so the second is used only by a burst, nothing is dropped and every frame is shown at the
    /// compositor's own delay but the one a burst queued. (A 58 fps source on that panel is told apart:
    /// `testOneTwentyHertzPanelShowsAFiftyEightFpsSourceWithOneInFlight`.)
    @MainActor
    func testASixtyFpsSourceInStepWithAOneTwentyHertzPanelLooksLikeSixtyHertzAndCostsNothing() throws {
        let sim = try DisplaySim(.init(period: 1.0 / 120, depth: 2, sourceEvery: 2, refreshRate: 120))
        sim.run(refreshes: 480)
        XCTAssertEqual(sim.pacer.cap, 2)
        XCTAssertTrue(sim.host.drops.isEmpty)
        XCTAssertGreaterThanOrEqual(sim.latencies.count, 238)
        for l in sim.latencies.map(\.refreshes) { XCTAssertEqual(l, 2, accuracy: 0.001) }
        // A burst queues one frame behind another for a refresh, and the next frame is on time again: the panel shows
        // a drawable every refresh and the source changes every other one, so the queue drains by itself.
        let burstAt = sim.refresh
        sim.burst(1)
        sim.run(refreshes: 120)
        XCTAssertEqual(sim.pacer.cap, 2)
        XCTAssertTrue(sim.host.drops.isEmpty)
        XCTAssertLessThanOrEqual(sim.latencies(capturedFromRefresh: burstAt).max() ?? 0, 3 + 0.001)
        let after = sim.latencies(capturedFromRefresh: burstAt + 1)
        XCTAssertGreaterThanOrEqual(after.count, 58)
        for l in after { XCTAssertEqual(l, 2, accuracy: 0.001) }
        sim.assertAccounting()
    }

    /// The gold divider dragged for a second over a source that changes every capture interval. Each frame carries the
    /// divider current when it arrives (the model pushes every decoded frame with it), so no move needs a redraw: one
    /// would take the drawable from the next frame, which would then be late and dropped, a frame lost per move (about
    /// 30 a second, the comparison at half rate and the dropped figure lit by the UI itself). Whatever the drag's rate
    /// and phase, with frames that come a little late, a late presented handler, a deep compositor or a 120 Hz panel:
    /// no frame dropped, no redraw, latency unchanged, and the last divider on screen. A frame 10 ms late, as one held up
    /// on the main thread by the drag's own work reaches the pacer, came after a redraw waiting only until the middle
    /// of the second interval, which took its drawable: the next frame waited, was held back as late and was dropped
    /// (the README's take, 2026-10-13).
    @MainActor
    func testDraggingTheDividerOverAMovingSourceCostsNoFrame() throws {
        let sources: [(name: String, config: DisplaySim.Config)] = [
            ("60 Hz", .init(compare: true)),
            ("late presented handler", .init(handlerDelay: 0.004, compare: true)),
            ("deep compositor", .init(depth: 2, compare: true)),
            ("120 Hz panel", .init(period: 1.0 / 120, sourceEvery: 2, compare: true)),
            ("every other frame 4 ms late", .init(compare: true, arrivalJitter: [0, 0.004])),
            ("frames up to 6 ms late", .init(compare: true, arrivalJitter: [0, 0.006, 0.002])),
            ("a frame in four 10 ms late", .init(compare: true, arrivalJitter: [0, 0, 0, 0.010])),
        ]
        for source in sources {
            for drag in Self.drags {
                try assertDragCostsNoFrame(source.config, rate: drag.rate, after: drag.after, label: source.name, redrawsAllowed: false)
            }
        }
    }

    /// The same drags over a source slower than the capture rate (30 fps), on a 60 Hz and a 120 Hz panel. Between two
    /// of its frames a move is drawn by a redraw, which lands while no frame is due, so it still costs no frame and no
    /// latency, and the last divider ends on screen.
    @MainActor
    func testDraggingTheDividerOverASlowerSourceCostsNoFrame() throws {
        let sources: [(name: String, config: DisplaySim.Config)] = [
            ("30 fps on 60 Hz", .init(sourceEvery: 2, compare: true)),
            ("30 fps on 60 Hz, late presented handler", .init(handlerDelay: 0.004, sourceEvery: 2, compare: true)),
            ("30 fps on 120 Hz", .init(period: 1.0 / 120, sourceEvery: 4, compare: true)),
        ]
        for source in sources {
            for drag in Self.drags + [(rate: 30, after: 0.015)] {
                try assertDragCostsNoFrame(source.config, rate: drag.rate, after: drag.after, label: source.name, redrawsAllowed: true)
            }
        }
    }

    /// The source goes still halfway through a drag: from then on no frame carries the moves, so the held comparison
    /// is drawn again with the newest divider, at most once per capture interval (not once per move), and the last
    /// divider ends on screen. Nothing is dropped, and nothing was redrawn while the source moved.
    @MainActor
    func testDividerDraggedAsTheSourceGoesStillIsRedrawnWithTheNewestDivider() throws {
        let sim = try DisplaySim(.init(compare: true))
        sim.run(refreshes: 60)
        sim.drag(moves: 120, every: 1.0 / 120)
        sim.run(refreshes: 30)
        XCTAssertEqual(sim.redraws, 0, "a moving source carries every move")
        sim.stopSource()
        sim.run(refreshes: 40)
        // About 30 capture intervals of dragging over the still source, 60 moves.
        XCTAssertGreaterThanOrEqual(sim.redraws, 20, "the moves are drawn while the drag goes on")
        XCTAssertLessThanOrEqual(sim.redraws, 31, "at most one redraw per capture interval")
        XCTAssertEqual(sim.host.renders.last?.kind, .redraw)
        XCTAssertEqual(sim.host.frames.last?.divider, sim.divider, "the last divider is on screen")
        XCTAssertEqual(sim.divider, 0.8, accuracy: 1e-9)
        XCTAssertTrue(sim.host.drops.isEmpty)
        XCTAssertNil(sim.pacer.pending)
        XCTAssertEqual(sim.pacer.inFlight, 0)
        sim.assertAccounting()
    }

    /// The codec loop turned off over a source that changes every capture interval: the source's next frame, raw now,
    /// takes the comparison's place, as it carries a divider move. The raw frame drawn at once took the drawable that
    /// frame needed, which then waited, was held back as late and was dropped: a frame lost at one loop off in four over
    /// the README's moving picture (2026-10-13). At any moment of the interval, with two drawables in flight on a 60 Hz
    /// panel, a deep compositor, a late presented handler, a 120 Hz panel and frames a little late: no frame dropped, no
    /// redraw, and the raw frame alone on screen with the next frame.
    @MainActor
    func testTurningTheLoopOffOverAMovingSourceCostsNoFrame() throws {
        let sources: [(name: String, config: DisplaySim.Config)] = [
            ("60 Hz", .init(compare: true, refreshRate: 60)),
            ("60 Hz, deep compositor", .init(depth: 2, compare: true, refreshRate: 60)),
            ("60 Hz, late presented handler", .init(handlerDelay: 0.004, compare: true, refreshRate: 60)),
            ("120 Hz panel", .init(period: 1.0 / 120, sourceEvery: 2, compare: true, refreshRate: 120)),
            ("frames up to 6 ms late", .init(compare: true, arrivalJitter: [0, 0.006, 0.002], refreshRate: 60)),
        ]
        for source in sources {
            for tenth in 1...9 {
                let delay = Double(tenth) / 10 / 60
                let what = "\(source.name), off \(String(format: "%.1f", delay * 1000)) ms after the last main-actor event"
                let sim = try DisplaySim(source.config)
                sim.run(refreshes: Int((1 / source.config.period).rounded()))
                let drops = sim.host.drops.count, redraws = sim.redraws
                sim.endComparison(after: delay)
                sim.run(refreshes: Int((0.5 / source.config.period).rounded()))
                XCTAssertEqual(sim.host.drops.count - drops, 0, "\(what): \(sim.redraws - redraws) redraws")
                XCTAssertEqual(sim.redraws - redraws, 0, "the next frame shows the raw picture: \(what)")
                XCTAssertNil(sim.host.frames.last?.compareWith, "the raw frame alone: \(what)")
                sim.assertAccounting()
            }
        }
    }

    /// Drag rates and the phase of the first move after the last main-actor event (`DisplaySim.drag`): 120 Hz (a
    /// trackpad), the display rate, half of it, 100 Hz (its moves drift across the frame interval), and 120 Hz starting
    /// right after a frame.
    private static let drags: [(rate: Double, after: Double)] = [(120, 0.003), (60, 0.003), (30, 0.003), (100, 0.003), (120, 0.0001)]

    /// A second of `config`'s source, then a second of dragging at `rate` and a fifth more: no frame dropped during the
    /// drag, every frame shown at the source's usual latency, and the last divider on screen.
    @MainActor
    private func assertDragCostsNoFrame(_ config: DisplaySim.Config, rate: Double, after delay: Double, label: String,
                                        redrawsAllowed: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        let what = "\(label), drag at \(Int(rate)) Hz from \(delay * 1000) ms"
        let sim = try DisplaySim(config)
        let second = Int((1 / config.period).rounded())
        sim.run(refreshes: second)
        let dropsBefore = sim.host.drops.count
        let redrawsBefore = sim.redraws
        let dragFrom = sim.refresh
        sim.drag(moves: Int(rate), every: 1 / rate, after: delay)
        sim.run(refreshes: second + second / 5)
        let drops = Array(sim.host.drops.dropFirst(dropsBefore))
        let shown = sim.latencies(capturedFromRefresh: dragFrom + 1).count
        XCTAssertEqual(drops.count, 0, "\(what): \(drops.filter { $0 == .backlog }.count) backlog drops, \(sim.redraws - redrawsBefore) redraws, \(shown) frames shown",
                       file: file, line: line)
        if !redrawsAllowed {
            XCTAssertEqual(sim.redraws - redrawsBefore, 0, "every move rides on the next frame: \(what)", file: file, line: line)
        }
        let after = sim.latencies(capturedFromRefresh: dragFrom + 1)
        XCTAssertGreaterThanOrEqual(after.count, (second + second / 5) / config.sourceEvery - 3, what, file: file, line: line)
        XCTAssertEqual(after.max() ?? 0, Double(config.depth), accuracy: 0.001, what, file: file, line: line)
        XCTAssertEqual(after.min() ?? 0, Double(config.depth), accuracy: 0.001, what, file: file, line: line)
        XCTAssertEqual(sim.host.frames.last?.divider, sim.divider, "the last divider is on screen: \(what)", file: file, line: line)
        XCTAssertEqual(sim.divider, 0.8, accuracy: 1e-9, what, file: file, line: line)
        sim.assertAccounting(file: file, line: line)
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

    /// A frame that never reached the view (`FrameSink.dropped`: a decoded picture a newer one replaced) is a dropped
    /// frame only while the view can show frames. With no view, or a view outside any window, it is a pause, `.hidden`,
    /// as a frame pushed then is (`FrameSink.push`, the pacer), so the dropped figure counts only frames a visible window
    /// lost.
    @MainActor
    func testAFrameThatNeverReachedTheViewIsDroppedOnlyWhileTheViewCanShowFrames() throws {
        let sink = FrameSink()
        let drops = DropLog()
        sink.onDropped = { drops.items.append($0) }
        sink.dropped(.replaced)
        let view = VideoView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        sink.view = view
        sink.dropped(.replaced)
        let display = ShowingDisplay()
        display.show(view)
        sink.dropped(.replaced)
        XCTAssertEqual(drops.items, [.hidden, .hidden, .replaced], "no view, a view in no window, a view on screen")
    }

    /// The review's case (spec 11, M6, amended 2026-10-12): the capture's first frame comes while the window is covered,
    /// so the view keeps it without drawing it, and a still source sends no other. When the window shows, the frame reaches
    /// the screen as a redraw: that lifts the share's cover, and counts as no display.
    @MainActor
    func testAFirstFrameHeldWhileTheWindowIsCoveredLiftsTheCoverWhenItIsRedrawn() async throws {
        let model = ShareModel(makeSource: { NeverSource() }, screenRecordingGranted: { true })
        model.state = .capturing
        let view = VideoView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        model.sink.view = view
        let display = ShowingDisplay()
        display.show(view)
        display.canShowFrames = false
        model.sink.push(try makeBuffer(), captureHostTimeNs: 9)
        XCTAssertTrue(display.drawn.isEmpty, "kept, not drawn")
        XCTAssertNil(model.firstFrameAt)
        display.canShowFrames = true
        view.pacer.redraw()   // what the window's occlusion or deminiaturize notification does
        XCTAssertEqual(display.drawn, [9])
        let deadline = Date().addingTimeInterval(2)
        while model.firstFrameAt == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(model.firstFrameAt, "the redraw lifts the cover")
        XCTAssertEqual(model.telemetry.snapshot(now: CACurrentMediaTime()).displayFPS, 0, "and is not a display")
        model.state = .idle
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
