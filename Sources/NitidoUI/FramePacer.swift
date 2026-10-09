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
    /// The highest refresh rate, in Hz, of the screen the window is on; 0 when it is not known.
    var refreshRate: Double { get }
    /// Renders `frame` into a fresh drawable and commits it. Returns nil once the drawable is committed; the
    /// host then calls `FramePacer.drawableReturned` when it is presented or discarded. Returns why otherwise.
    func render(_ frame: FramePacer.Frame, kind: FramePacer.Kind) -> VideoView.Drop?
    func framePresented(captureHostTimeNs: UInt64, at presentedAt: Double)
    func frameDropped(_ drop: VideoView.Drop)
}

/// Decides when the video view draws. It keeps exactly one frame, the newest, so the picture can be drawn
/// again when the drawable changes size or the window shows again: ScreenCaptureKit only sends changed frames,
/// so a still source would otherwise stay stretched or stale. Redraws respect the frames-in-flight cap and are
/// never reported as presented, so they add nothing to display fps or latency. A captured frame that meets the
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
/// `displayChanged`). A 120 Hz panel starts at one. A frame that waited at the cap through a refresh (the drawable
/// ahead of it was shown after it arrived) is held back for one capture interval with the drawable free: a newer frame
/// replaces it (one `.backlog` drop) and is drawn at once into the emptier queue, which brings latency back to the
/// display's own; if none comes, the source went still and the held-back frame is drawn then. A frame that waited only
/// because the presented handler reached the main actor after it is drawn at once. If frames keep starving at the cap,
/// the display keeps each drawable longer than the pacer expected, and the cap rises by one, up to the pool size minus
/// one. It steps back down by one after ten seconds without starving (on `now`, whatever the refresh rate), never below
/// `minimumCap`, so a transient (a Space switch, Mission Control, a main-thread hitch) does not cost a refresh of
/// latency for the rest of the session.
@MainActor
final class FramePacer {
    struct Frame {
        let pixelBuffer: CVPixelBuffer
        let captureHostTimeNs: UInt64
        /// Loopback: the raw frame shown left of `divider` (0...1), the main buffer on the right. Nil shows the main
        /// buffer alone. The held frame keeps it too, so a redraw shows the same comparison.
        var compareWith: CVPixelBuffer? = nil
        var divider: CGFloat = 0.5
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
    /// than twice the capture rate, one on a faster one (`minimumCap(refreshRate:drawableCount:)`). One until the pacer
    /// knows the display (`displayChanged`).
    private(set) var minimumCap = 1
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
    /// A divider move waits for a redraw (`moveDivider`); a new frame, any redraw or a release makes it moot.
    private var dividerRedrawScheduled = false
    /// Bumped whenever the scheduled divider redraw becomes moot, so it then does nothing.
    private var dividerRedrawToken: UInt64 = 0

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
    /// frame, the second interval at the earliest. A source that changes every interval has sent its next frame by
    /// then with half an interval to spare, so a frame a little late still carries the move. A slower one sends its
    /// frames whole intervals apart on a 60 Hz display, so the redraw lands half an interval clear of them and never
    /// takes the drawable one of them needs. On a still source the move is drawn within one interval.
    private func dividerRedrawDelay() -> CFTimeInterval {
        let interval = Self.lateFrameGrace
        let elapsed = now() - lastArrival
        let intervals = max(1, (elapsed / interval - 0.5).rounded(.up))
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
    /// starts afresh on top of that. Nothing when the display needs what the last one did, or does not say its rate.
    func displayChanged() {
        guard let host, host.refreshRate > 0 else { return }
        let needed = Self.minimumCap(refreshRate: host.refreshRate, drawableCount: host.drawableCount)
        guard needed != minimumCap else { return }
        minimumCap = needed
        cap = needed
        starvedReturns = 0
        calmSince = now()
        lowerAfter = Self.calmBeforeLower
        loweredAt = nil
        log.info("The display refreshes at \(host.refreshRate, format: .fixed(precision: 0), privacy: .public) Hz: allowing \(self.cap, privacy: .public) in flight")
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
        guard drawableSize.width > 0, drawableSize.height > 0, host.canShowFrames else {
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
