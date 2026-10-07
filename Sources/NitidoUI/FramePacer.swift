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
/// Queue depth. Presentation is in order, one drawable per refresh, so every drawable queued ahead of a frame
/// delays it by a refresh, and a source that changes at the display rate keeps that delay for good: one frame
/// arrives and one is shown per refresh, so the queue never drains on its own. The pacer therefore keeps one
/// drawable in flight (`cap`). A frame that waited at the cap through a refresh (the drawable ahead of it was shown
/// after it arrived) is held back for one capture interval with the drawable free: a newer frame replaces it (one
/// `.backlog` drop) and is drawn at once into the empty queue, which brings latency back to one refresh; if none
/// comes, the source went still and the held-back frame is drawn then. A frame that waited only because the
/// presented handler reached the main actor after it is drawn at once. If frames keep starving at the cap, the
/// display keeps each drawable longer than a refresh, and the cap rises by one, up to the pool size minus one.
@MainActor
final class FramePacer {
    struct Frame {
        let pixelBuffer: CVPixelBuffer
        let captureHostTimeNs: UInt64
    }

    enum Kind: Sendable, Equatable {
        /// A frame just captured: counted as displayed or dropped.
        case live
        /// The held frame drawn again: neither a display nor a drop.
        case redraw
    }

    /// How long a late frame is held back for a newer one: the capture interval (`CaptureSession` asks for at most
    /// 60 fps), so a source that keeps changing sends its next frame within it.
    static let lateFrameGrace: CFTimeInterval = 1.0 / 60
    /// Drawable returns in a row that find a frame starved before one more drawable may be in flight.
    static let starvedReturnsBeforeRaise = 6

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
    /// Drawables allowed in flight. One to start: the compositor may still hold the drawable shown before the
    /// current one, so with the usual pool of three a second one queued could make nextDrawable() block the main
    /// thread, and one queued drawable is all a frame needs to be shown at the next refresh.
    private(set) var cap = 1
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
    /// Presented time of the last drawable shown, for the spacing in the debug log.
    private var lastPresentedAt: Double = 0

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
        waitingHeldBack = false
        lateDrawToken &+= 1
        submit(frame, kind: .live)
    }

    /// Draws the held frame again, for example when the window shows after being minimized, covered or hidden.
    func redraw() {
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

    /// The presented handler of a committed drawable. `presentedAt` is 0 when the drawable was discarded.
    func drawableReturned(kind: Kind, captureHostTimeNs: UInt64, presentedAt: Double) {
        inFlight = max(0, inFlight - 1)
        lastActivity = now()
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
        noteReturn(starved: waitingLive && (late || replacedSinceReturn))
        guard let waiting = pending else { return }
        if waiting == .live, late, !waitingHeldBack {
            holdBackLateFrame(waitedPastRefresh: presentedAt - waitingSince)
            return
        }
        pending = nil
        if let held { submit(held, kind: waiting) }
    }

    /// Lets go of the held frame so its buffer goes back to the capture pool.
    func releaseHeldFrame() {
        held = nil
        pending = nil
        waitingHeldBack = false
        lateDrawToken &+= 1
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

    /// Counts drawable returns that found a live frame starved; enough in a row raise the cap by one.
    private func noteReturn(starved: Bool) {
        replacedSinceReturn = false
        starvedReturns = starved ? starvedReturns + 1 : 0
        guard starvedReturns >= Self.starvedReturnsBeforeRaise, let host, cap < max(1, host.drawableCount - 1) else { return }
        cap += 1
        starvedReturns = 0
        log.info("Frames kept waiting for a drawable: the display holds each one longer than a refresh. Allowing \(self.cap, privacy: .public) in flight")
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
