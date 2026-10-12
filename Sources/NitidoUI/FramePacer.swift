import CoreVideo
import Foundation
import QuartzCore
import os

private let log = Logger(subsystem: "ai.ronar.nitido", category: "video")
/// Intervals and events for Instruments (the wait inside nextDrawable(), arrivals, presentations).
let videoSignposter = OSSignposter(subsystem: "ai.ronar.nitido", category: "video")

/// What `FramePacer` drives. `VideoView` is the real one; tests use a fake.
@MainActor
protocol FrameDrawing: AnyObject {
    /// True while the window can show a picture (visible on screen, not minimized, not fully covered).
    var canShowFrames: Bool { get }
    /// The layer's drawable pool size.
    var drawableCount: Int { get }
    /// The highest refresh rate, in Hz, of the screen the window is on; 0 when it is not known. Nominal: ProMotion may
    /// run the panel slower, which the pacer sees in when its drawables are presented
    /// (`FramePacer.slowRefreshInterval`).
    var refreshRate: Double { get }
    /// Renders `frame` into a fresh drawable and commits it. Returns nil once the drawable is committed; the
    /// host then calls `FramePacer.drawableReturned` when it is presented or discarded. Returns why otherwise.
    func render(_ frame: FramePacer.Frame, kind: FramePacer.Kind) -> VideoView.Drop?
    /// A captured frame reached the screen: a display, with its latency.
    func framePresented(captureHostTimeNs: UInt64, at presentedAt: Double)
    /// A drawable reached the screen, whatever it held: a captured frame (also reported to `framePresented`) or the
    /// held frame drawn again. What lifts the picture's cover (`PictureCover`): a first frame that came while the window
    /// could not draw it reaches the screen only as a redraw. Never a display.
    func frameShown(kind: FramePacer.Kind, at presentedAt: Double)
    func frameDropped(_ drop: VideoView.Drop)
}

/// Decides when the video view draws. It keeps exactly one frame, the newest, so the picture can be drawn
/// again when the drawable changes size or the window shows again: ScreenCaptureKit only sends changed frames,
/// so a still source would otherwise stay stretched or stale. Redraws respect the frames-in-flight cap and are
/// never reported as presented, so they add nothing to display fps or latency; every drawable that reaches the screen,
/// a redraw included, is reported as shown (`frameShown`), which counts towards nothing. A captured frame that meets the
/// cap waits for the next drawable as a live frame, so it still counts as displayed, with its real latency; it
/// is a dropped frame only when a newer one replaces it before it was drawn.
///
/// Queue depth. Presentation is in order, one drawable per refresh, so every drawable queued ahead of a frame delays it
/// by a refresh, and a source that changes at the display rate keeps that delay for good: one frame arrives and one is
/// shown per refresh, so the queue never drains on its own. The pacer therefore keeps as few drawables in flight
/// (`cap`) as the display needs. One drawable in flight costs each frame two refreshes (the compositor puts a drawable
/// on the glass at the second refresh after its commit, and the presented handler that frees the slot comes no sooner),
/// so a panel slower than twice the capture rate, 60 Hz among them, could show only every other frame of a 60 fps
/// source with one: it starts at two and never goes below (`minimumCap`, taken from the screen the window is on by
/// `displayChanged`). A 120 Hz panel starts at one. A screen's nominal rate is not always the rate drawables are
/// presented at: on the second two-Mac test (2026-10-09) a MacBook Pro whose screen said 120 Hz presented them every
/// 16.7 ms, which is a panel ProMotion runs at 60 Hz or a 60 fps source in step with a 120 Hz one, starving at one in
/// flight either way. So the pacer also measures when its drawables are presented, over each second, and takes gaps
/// of 1.5 times the nominal interval or more for the slower rate they show
/// (`slowRefreshInterval`): two in flight while that lasts. A frame that waited at the cap through a refresh (the
/// drawable ahead of it was shown after it arrived) is held back for one capture interval with the drawable free: a
/// newer frame replaces it (one `.backlog` drop) and is drawn at once into the emptier queue, which brings latency back
/// to the display's own; if none comes, the source went still and the held-back frame is drawn then. A frame that
/// waited only because the presented handler reached the main actor after it is drawn at once. If frames keep starving
/// at the cap, the display keeps each drawable longer than the pacer expected, and the cap rises by one, up to the pool
/// size minus one. It steps back down by one after ten seconds without starving (on `now`, whatever the refresh rate),
/// never below `minimumCap`, so a transient (a Space switch, Mission Control, a main-thread hitch) does not cost a
/// refresh of latency for the rest of the session.
@MainActor
final class FramePacer {
    struct Frame {
        let pixelBuffer: CVPixelBuffer
        let captureHostTimeNs: UInt64
        /// Loopback: the raw frame shown left of `divider` (0...1), the main buffer on the right. Nil shows the main
        /// buffer alone. The held frame keeps it too, so a redraw shows the same comparison.
        var compareWith: CVPixelBuffer? = nil
        var divider: CGFloat = 0.5
        /// The picture's size when the buffer is larger: a decoded picture of an odd size, whose buffer carries the
        /// column or row its encoder added (`DecodedFrame`). Nil draws the whole buffer.
        var pictureSize: CGSize? = nil
    }

    enum Kind: Sendable, Equatable {
        /// A frame just captured: counted as displayed or dropped.
        case live
        /// The held frame drawn again: neither a display nor a drop.
        case redraw
    }

    /// The highest rate a source changes at: `CaptureSession` asks for at most 60 fps, on the viewer too (its frames
    /// come from the sharer's capture).
    static let captureRate: Double = 60
    /// How long a late frame is held back for a newer one: the capture interval, so a source that keeps changing sends
    /// its next frame within it.
    static let lateFrameGrace: CFTimeInterval = 1.0 / captureRate
    /// Drawable returns in a row that find a frame starved before one more drawable may be in flight.
    static let starvedReturnsBeforeRaise = 6
    /// Seconds without a starved frame before one drawable fewer may be in flight again.
    static let calmBeforeLower: CFTimeInterval = 10
    /// The presentations the cadence is measured over, and how often it is: the last second of them, every second.
    static let cadenceWindow: CFTimeInterval = 1
    /// Gaps between presentations a second must hold before its cadence says anything about the panel: a source near
    /// the capture rate. A slower one is presented as slowly on any panel.
    static let cadenceSamples = 40

    weak var host: (any FrameDrawing)?
    var now: () -> CFTimeInterval = { CACurrentMediaTime() }
    /// Runs `action` on the main actor after `delay` seconds. Tests run it by hand or in simulated time.
    var schedule: (_ delay: CFTimeInterval, _ action: @escaping @MainActor @Sendable () -> Void) -> Void = { delay, action in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { action() } }
    }

    /// The newest frame handed to `present`, drawn or not. One buffer only: ScreenCaptureKit's pool is small.
    private(set) var held: Frame?
    /// Frames committed whose drawable has not been presented or discarded yet.
    private(set) var inFlight = 0
    /// Drawables allowed in flight: `minimumCap` to start, raised while frames keep starving, lowered after a calm.
    private(set) var cap = 1
    /// The fewest drawables in flight the display needs to show a source at the capture rate: two on a panel slower
    /// than twice the capture rate, one on a faster one (`minimumCap(refreshRate:drawableCount:)`), by the screen's
    /// rate or by the rate its presentations show, whichever needs more. One until the pacer knows the display.
    var minimumCap: Int { max(screenFloor, cadenceFloor) }
    /// What the screen's nominal rate needs (`displayChanged`).
    private var screenFloor = 1
    /// What the rate the presentations show needs (`measureCadence`); one while they show the nominal rate.
    private var cadenceFloor = 1
    /// The screen's nominal rate, in Hz; 0 until `displayChanged` knows it, and the cadence is not measured until then.
    private var nominalRate: Double = 0
    /// Presented times of the last `cadenceWindow`, oldest first.
    private var presentations: [Double] = []
    /// When the cadence was last measured, on `now`; nil until the first presentation after the rate became known.
    private var cadenceMeasuredAt: CFTimeInterval?
    /// The held frame met the cap and is drawn as this kind when a drawable is free, unless a live frame is
    /// committed first. `.live`: a captured frame not drawn yet, counted as displayed once it is shown, or as
    /// dropped if a newer frame replaces it first. `.redraw`: the held frame drawn again (resize, reveal).
    private(set) var pending: Kind?
    /// Last commit or drawable return; a backlog with no movement for a second means a lost handler.
    private var lastActivity: CFTimeInterval = 0
    /// When the waiting live frame arrived. A drawable presented after this moment means it waited through a refresh.
    private var waitingSince: CFTimeInterval = 0
    /// The waiting live frame was held back once already; the next chance draws it.
    private var waitingHeldBack = false
    /// Bumped whenever the waiting live frame changes, so a late draw scheduled for an earlier one does nothing.
    private var lateDrawToken: UInt64 = 0
    /// A waiting live frame was replaced since the last drawable return.
    private var replacedSinceReturn = false
    /// Drawable returns in a row that found a live frame starved: late, or replacing another while it waited.
    private var starvedReturns = 0
    /// The last drawable return that found a live frame starved, or that lowered the cap: the calm counts from there.
    private var calmSince: CFTimeInterval = 0
    /// Seconds of calm that lower the cap. Doubles (up to `longestWaitBeforeLower`) each time the cap has to rise again
    /// within this long of being lowered: that display needs the deeper queue.
    private var lowerAfter = FramePacer.calmBeforeLower
    private static let longestWaitBeforeLower = 8 * FramePacer.calmBeforeLower
    /// When the cap was last lowered; nil until it first is.
    private var loweredAt: CFTimeInterval?
    /// Presented time of the last drawable shown, for the spacing in the debug log.
    private var lastPresentedAt: Double = 0
    /// When the newest frame reached `present`: a divider move waits for the frame after it (`moveDivider`).
    private var lastArrival: CFTimeInterval = 0
    /// When the two frames before it reached `present`, the later first, 0 for none yet: whether the source changes
    /// every capture interval (`dividerRedrawDelay`).
    private var earlierArrivals: (CFTimeInterval, CFTimeInterval) = (0, 0)
    /// A divider move waits for a redraw (`moveDivider`); a new frame, any redraw or a release makes it moot.
    private var dividerRedrawScheduled = false
    /// Bumped whenever the scheduled divider redraw becomes moot, so it then does nothing.
    private var dividerRedrawToken: UInt64 = 0

    /// The host can draw a frame now: its window can show the picture and the drawable has a size. A frame that arrives
    /// while it cannot is kept and reported as a pause (`.hidden`), not a drop.
    var canDraw: Bool {
        guard let host else { return false }
        return drawableSize.width > 0 && drawableSize.height > 0 && host.canShowFrames
    }

    /// The drawable's pixel size. A real change draws the held frame again at the new size.
    var drawableSize: CGSize = .zero {
        didSet { if drawableSize != oldValue { redraw() } }
    }

    /// A new captured frame: becomes the held frame (also when it cannot be drawn now) and is drawn if possible.
    func present(_ frame: Frame) {
        let arrival = now()
        videoSignposter.emitEvent("arrive")
        log.debug("Arrive \(frame.captureHostTimeNs, privacy: .public) at \(arrival, format: .fixed(precision: 4), privacy: .public): \(self.inFlight, privacy: .public) of \(self.cap, privacy: .public) in flight, waiting \(self.pending == .live, privacy: .public)")
        if pending == .live {
            // The frame waiting for a drawable never reached the screen, and this newer one replaces it.
            pending = nil
            replacedSinceReturn = true
            host?.frameDropped(.backlog)
        }
        held = frame
        waitingSince = arrival
        earlierArrivals = (lastArrival, earlierArrivals.0)
        lastArrival = arrival
        waitingHeldBack = false
        lateDrawToken &+= 1
        cancelDividerRedraw()   // this frame carries the current divider
        submit(frame, kind: .live)
    }

    /// Draws the held frame again, for example when the window shows after being minimized, covered or hidden.
    func redraw() {
        cancelDividerRedraw()   // the held frame drawn now, or when it can be, carries the newest divider
        guard let held else { return }
        if pending == .live {
            // Not on screen yet: it is still a captured frame, drawn now if a drawable is free (also when it was
            // held back as late), else it keeps waiting.
            pending = nil
            submit(held, kind: .live)
        } else {
            submit(held, kind: .redraw)
        }
    }

    /// Moves the held frame's comparison divider. Nothing when the held frame shows no comparison or already splits
    /// there. A moving source shows the move with its next frame (the model pushes every decoded frame with the current
    /// divider), and a frame or redraw already waiting for a drawable is drawn with it, so neither needs a redraw: one
    /// would take the drawable from the next frame, which would wait behind it, be late and be dropped, a frame lost
    /// per move while the divider is dragged. Only a still source needs the held frame drawn again, so the redraw
    /// waits until the next frame is overdue (`dividerRedrawDelay`) and does nothing if a frame came first. Moves
    /// until then ride on that one redraw.
    func moveDivider(to divider: CGFloat) {
        guard var frame = held, frame.compareWith != nil, frame.divider != divider else { return }
        frame.divider = divider
        held = frame
        guard pending == nil, !dividerRedrawScheduled else { return }
        dividerRedrawScheduled = true
        let token = dividerRedrawToken
        schedule(dividerRedrawDelay()) { [weak self] in
            guard let self, token == dividerRedrawToken else { return }
            redraw()
        }
    }

    /// How long a divider move waits for a frame to carry it: until the middle of a capture interval after the newest
    /// frame, the second interval at the earliest, or the third for a source that changes every interval (one of its
    /// last two frames came within an interval and a half of the one before). Such a source sends its next frame within
    /// the second interval, and one held up on its way, by the main thread that also handles the drag, a little later
    /// still: it carries the move, and a redraw at the middle of the second interval would take the drawable from a
    /// frame more than half an interval late, which would then wait behind it, be held back as late and be dropped (the
    /// README's take, 2026-10-13: a frame 10 ms late). A slower one sends its frames whole intervals apart on a 60 Hz
    /// display, so the redraw lands half an interval clear of them and never takes the drawable one of them needs. On a
    /// still source the move is drawn within one interval.
    private func dividerRedrawDelay() -> CFTimeInterval {
        let interval = Self.lateFrameGrace
        let elapsed = now() - lastArrival
        let (before, beforeThat) = earlierArrivals
        let everyInterval = before > 0
            && (lastArrival - before < 1.5 * interval || beforeThat > 0 && before - beforeThat < 1.5 * interval)
        let intervals = max(everyInterval ? 2 : 1, (elapsed / interval - 0.5).rounded(.up))
        return max(0, (intervals + 0.5) * interval - elapsed)
    }

    private func cancelDividerRedraw() {
        dividerRedrawScheduled = false
        dividerRedrawToken &+= 1
    }

    /// Puts `frame` in place of the held one and draws it again, the way a resize does: the codec loop was turned
    /// off, so the raw frame replaces the comparison at once instead of when the source next changes. A frame still
    /// waiting for a drawable is drawn as this one and counted as displayed once; otherwise it is a redraw.
    func replaceHeld(with frame: Frame) {
        held = frame
        redraw()
    }

    /// The presented handler of a committed drawable. `presentedAt` is 0 when the drawable was discarded.
    func drawableReturned(kind: Kind, captureHostTimeNs: UInt64, presentedAt: Double) {
        inFlight = max(0, inFlight - 1)
        let returnedAt = now()
        lastActivity = returnedAt
        if presentedAt > 0 {
            videoSignposter.emitEvent("presented")
            let spacing = lastPresentedAt > 0 ? (presentedAt - lastPresentedAt) * 1000 : 0
            log.debug("Presented \(kind == .live ? "live" : "redraw", privacy: .public) at \(presentedAt, format: .fixed(precision: 4), privacy: .public), \(spacing, format: .fixed(precision: 1), privacy: .public) ms after the previous one, latency \((presentedAt - Double(captureHostTimeNs) / 1e9) * 1000, format: .fixed(precision: 1), privacy: .public) ms; \(self.inFlight, privacy: .public) of \(self.cap, privacy: .public) still in flight, waiting \(self.pending == .live, privacy: .public)")
            lastPresentedAt = presentedAt
            notePresentation(at: presentedAt, returnedAt: returnedAt)
            host?.frameShown(kind: kind, at: presentedAt)
        }
        if kind == .live {
            // A discarded drawable reports 0: count it as dropped, never as a display at time zero.
            if presentedAt > 0 {
                host?.framePresented(captureHostTimeNs: captureHostTimeNs, at: presentedAt)
            } else {
                host?.frameDropped(.notPresented)
            }
        }
        let waitingLive = pending == .live
        // Shown after the waiting frame arrived: that frame waited through a refresh, not just for this handler.
        let late = waitingLive && presentedAt > waitingSince
        noteReturn(starved: waitingLive && (late || replacedSinceReturn), at: returnedAt)
        guard let waiting = pending else { return }
        if waiting == .live, late, !waitingHeldBack {
            holdBackLateFrame(waitedPastRefresh: presentedAt - waitingSince)
            return
        }
        pending = nil
        if let held { submit(held, kind: waiting) }
    }

    /// The window is on a screen for the first time, moved to another, or its screen changed mode: the cap starts again
    /// from what this display needs (`minimumCap(refreshRate:drawableCount:)`), and the rule that raises and lowers it
    /// starts afresh on top of that. Nothing when the display needs what the last one did, or does not say its rate. A
    /// new rate also starts the presentation cadence afresh: what it showed was measured against the old one.
    func displayChanged() {
        guard let host, host.refreshRate > 0 else { return }
        if host.refreshRate != nominalRate {
            nominalRate = host.refreshRate
            presentations.removeAll()
            cadenceMeasuredAt = nil
            // A cap the old cadence raised steps down only after a calm from here, as it does when the cadence changes.
            if cadenceFloor > 1 { calmSince = now() }
            cadenceFloor = 1
        }
        let needed = Self.minimumCap(refreshRate: host.refreshRate, drawableCount: host.drawableCount)
        guard needed != screenFloor else { return }
        screenFloor = needed
        cap = minimumCap
        starvedReturns = 0
        calmSince = now()
        lowerAfter = Self.calmBeforeLower
        loweredAt = nil
        log.info("The display refreshes at \(host.refreshRate, format: .fixed(precision: 0), privacy: .public) Hz: allowing \(self.cap, privacy: .public) in flight")
    }

    /// Keeps the last second of presented times and, once a second, measures their cadence (`measureCadence`).
    private func notePresentation(at presentedAt: Double, returnedAt: CFTimeInterval) {
        guard nominalRate > 0 else { return }
        if let last = presentations.last, presentedAt <= last { return }
        presentations.append(presentedAt)
        if let stale = presentations.firstIndex(where: { $0 >= presentedAt - Self.cadenceWindow }), stale > 0 {
            presentations.removeFirst(stale)
        }
        guard let measured = cadenceMeasuredAt else { cadenceMeasuredAt = returnedAt; return }
        guard returnedAt - measured >= Self.cadenceWindow else { return }
        cadenceMeasuredAt = returnedAt
        measureCadence(at: returnedAt)
    }

    /// The rate the last second's presentations show sets `cadenceFloor`: two in flight while the panel presents at 1.5
    /// times the nominal interval or slower, the screen's own floor otherwise. Raised, the cap follows at once;
    /// lowered, the cap steps down by the usual rule, after `lowerAfter` seconds of calm counted from now.
    private func measureCadence(at now: CFTimeInterval) {
        guard let host else { return }
        let gaps = zip(presentations.dropFirst(), presentations).map { $0 - $1 }
        guard gaps.count >= Self.cadenceSamples else { return }
        let slow = Self.slowRefreshInterval(gaps: gaps, nominal: 1 / nominalRate)
        let floor = slow.map { Self.minimumCap(refreshRate: 1 / $0, drawableCount: host.drawableCount) } ?? 1
        guard floor != cadenceFloor else { return }
        let raised = floor > cadenceFloor
        cadenceFloor = floor
        calmSince = now
        let shown = (slow ?? gaps.min() ?? 0) * 1000
        if raised {
            cap = max(cap, minimumCap)
            log.info("Drawables are presented every \(shown, format: .fixed(precision: 1), privacy: .public) ms although the display says \(self.nominalRate, format: .fixed(precision: 0), privacy: .public) Hz: allowing \(self.cap, privacy: .public) in flight")
        } else {
            log.info("Drawables are presented as often as the display's \(self.nominalRate, format: .fixed(precision: 0), privacy: .public) Hz allows again: \(self.cap, privacy: .public) in flight until \(self.lowerAfter, format: .fixed(precision: 0), privacy: .public) s of calm")
        }
    }

    /// The refresh interval a second of gaps between presentations shows, when it is at least 1.5 times the nominal
    /// one: the longest interval of which every gap is a whole multiple, to within a quarter of a nominal refresh,
    /// tried among the shortest gap and its half, third and quarter. Nil when only a shorter one fits: the panel shows
    /// frames at a rate closer to its nominal one. A 58 fps source on a 120 Hz panel is presented 16.7 or 25 ms apart,
    /// and 25 ms is no multiple of 16.7: nil. On a panel at 60 Hz the gaps are 16.7 or 33.3 ms: 16.7 ms. A 60 fps
    /// source in step with a 120 Hz panel is presented every 16.7 ms as well, which no cadence can tell from 60 Hz.
    static func slowRefreshInterval(gaps: [Double], nominal: Double) -> Double? {
        guard let shortest = gaps.min(), shortest > 0 else { return nil }
        let tolerance = nominal / 4
        for divisor in 1...4 {
            let interval = shortest / Double(divisor)
            guard interval >= 1.5 * nominal else { return nil }
            let fits = gaps.allSatisfy { gap in
                let multiple = (gap / interval).rounded()
                return multiple >= 1 && abs(gap - multiple * interval) <= tolerance
            }
            if fits { return interval }
        }
        return nil
    }

    /// Two drawables in flight on a panel slower than twice the capture rate (60 Hz, also 59.94, 75, 90 or 100 Hz), one
    /// on a faster one. One drawable in flight costs a frame two refreshes: the compositor puts it on the glass at the
    /// second refresh after its commit, and its presented handler, which frees the slot, comes no sooner (with one in
    /// flight the two-Mac test's 60 Hz viewer showed 33 fps of a 58 fps source). Where two refreshes last longer than a
    /// capture interval, every frame needs the next drawable queued behind the one on its way: one shown and one
    /// queued. A 120 Hz panel shows a 60 fps source with one, and a second would only add a refresh of latency after a
    /// burst. Never more than the pool minus one: the layer keeps three drawables (`VideoView`), one on screen, one on
    /// its way and one being drawn.
    static func minimumCap(refreshRate: Double, drawableCount: Int) -> Int {
        let wanted = refreshRate < 2 * captureRate - 1 ? 2 : 1
        return min(wanted, max(1, drawableCount - 1))
    }

    /// Lets go of the held frame so its buffer goes back to the capture pool.
    func releaseHeldFrame() {
        held = nil
        pending = nil
        waitingHeldBack = false
        lateDrawToken &+= 1
        cancelDividerRedraw()
    }

    /// The waiting frame waited through a refresh, so the drawable queue is a refresh deeper than it needs to be,
    /// and with a source that changes every refresh it would stay that way. Keep the drawable free for one capture
    /// interval: a newer frame replaces this one and is drawn at once; if none comes, this one is drawn then.
    private func holdBackLateFrame(waitedPastRefresh: CFTimeInterval) {
        waitingHeldBack = true
        lateDrawToken &+= 1
        let token = lateDrawToken
        log.debug("Held back a frame that arrived \(waitedPastRefresh * 1000, format: .fixed(precision: 2), privacy: .public) ms before the refresh it waited through, for a newer one")
        schedule(Self.lateFrameGrace) { [weak self] in
            guard let self, token == lateDrawToken, pending == .live, let held else { return }
            pending = nil
            submit(held, kind: .live)
        }
    }

    /// Counts drawable returns that found a live frame starved; enough in a row raise the cap by one. A return
    /// `lowerAfter` seconds after the last starved one (or the last lowering) lowers it by one again, never below
    /// `minimumCap`.
    /// The calm is measured on `now`, so it lasts as long at 120 Hz or with a 30 fps source as at 60 Hz.
    private func noteReturn(starved: Bool, at now: CFTimeInterval) {
        replacedSinceReturn = false
        starvedReturns = starved ? starvedReturns + 1 : 0
        if starved { calmSince = now }
        if starvedReturns >= Self.starvedReturnsBeforeRaise, let host, cap < max(1, host.drawableCount - 1) {
            cap += 1
            starvedReturns = 0
            if let lowered = loweredAt, now - lowered < lowerAfter { lowerAfter = min(2 * lowerAfter, Self.longestWaitBeforeLower) }
            log.info("Frames kept waiting for a drawable: the display holds each one longer than a refresh. Allowing \(self.cap, privacy: .public) in flight")
        } else if cap > minimumCap, now - calmSince >= lowerAfter {
            cap -= 1
            calmSince = now
            loweredAt = now
            log.info("Drawables come back in time again: allowing \(self.cap, privacy: .public) in flight")
        }
    }

    private func submit(_ frame: Frame, kind: Kind) {
        guard let host else { return }
        guard canDraw else {
            // Kept in `held`: drawn when the window shows again or gets its size.
            if kind == .live { host.frameDropped(.hidden) }
            return
        }
        if inFlight >= cap {
            if now() - lastActivity <= 1 {
                // Wait for the next drawable. A live frame waits as live (it is the held one, the newest): it is drawn
                // when a drawable comes back and counted as displayed then, with the wait in its latency. A redraw never
                // lands here over a waiting live frame: `redraw()` submits that frame as live.
                pending = kind
                return
            }
            log.error("No drawable came back for 1 s with \(self.inFlight, privacy: .public) frames in flight; resetting the count")
            inFlight = 0
        }
        if let drop = host.render(frame, kind: kind) {
            switch (kind, drop) {
            case (.live, _), (.redraw, .failed):
                // A redraw is not a captured frame, but a render failure is still a failure the user must see.
                host.frameDropped(drop)
            case (.redraw, _):
                log.error("Could not redraw the last frame: no drawable became available")
            }
            return
        }
        if kind == .live { pending = nil }
        inFlight += 1
        lastActivity = now()
    }
}
