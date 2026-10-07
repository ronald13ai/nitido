import CoreVideo
import QuartzCore
import os

private let log = Logger(subsystem: "ai.ronar.nitido", category: "video")

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

    weak var host: (any FrameDrawing)?
    var now: () -> CFTimeInterval = { CACurrentMediaTime() }

    /// The newest frame handed to `present`, drawn or not. One buffer only: ScreenCaptureKit's pool is small.
    private(set) var held: Frame?
    /// Frames committed whose drawable has not been presented or discarded yet.
    private(set) var inFlight = 0
    /// Last commit or drawable return; a backlog with no movement for a second means a lost handler.
    private var lastActivity: CFTimeInterval = 0
    /// The held frame met the cap and is drawn as this kind when the next drawable comes back, unless a live
    /// frame is committed first. `.live`: a captured frame not drawn yet, counted as displayed once it is shown,
    /// or as dropped if a newer frame replaces it first. `.redraw`: the held frame drawn again (resize, reveal).
    private var pending: Kind?

    /// The drawable's pixel size. A real change draws the held frame again at the new size.
    var drawableSize: CGSize = .zero {
        didSet { if drawableSize != oldValue { redraw() } }
    }

    /// A new captured frame: becomes the held frame (also when it cannot be drawn now) and is drawn if possible.
    func present(_ frame: Frame) {
        if pending == .live {
            // The frame waiting for a drawable never reached the screen, and this newer one replaces it.
            pending = nil
            host?.frameDropped(.backlog)
        }
        held = frame
        submit(frame, kind: .live)
    }

    /// Draws the held frame again, for example when the window shows after being minimized, covered or hidden.
    func redraw() {
        guard let held else { return }
        if pending == .live {
            // Not on screen yet: it is still a captured frame, drawn now if a drawable is free, else it keeps waiting.
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
        if kind == .live {
            // A discarded drawable reports 0: count it as dropped, never as a display at time zero.
            if presentedAt > 0 {
                host?.framePresented(captureHostTimeNs: captureHostTimeNs, at: presentedAt)
            } else {
                host?.frameDropped(.notPresented)
            }
        }
        if let kind = pending {
            pending = nil
            if let held { submit(held, kind: kind) }
        }
    }

    /// Lets go of the held frame so its buffer goes back to the capture pool.
    func releaseHeldFrame() {
        held = nil
        pending = nil
    }

    private func submit(_ frame: Frame, kind: Kind) {
        guard let host else { return }
        guard drawableSize.width > 0, drawableSize.height > 0, host.canShowFrames else {
            // Kept in `held`: drawn when the window shows again or gets its size.
            if kind == .live { host.frameDropped(.hidden) }
            return
        }
        // One drawable is on screen and one may be queued; only ask for another when a third is free,
        // so nextDrawable() returns at once instead of blocking the main thread.
        if inFlight >= max(1, host.drawableCount - 1) {
            if now() - lastActivity <= 1 {
                // Wait for the next drawable. A live frame waits as live (it is the held one, the newest): it is drawn
                // when a drawable comes back and counted as displayed then, with the wait in its latency. Reporting
                // it dropped and drawing it as an uncounted redraw would take that drawable from the next live
                // frame, which then meets the cap too. A redraw never lands here over a waiting live frame:
                // `redraw()` submits that frame as live.
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
