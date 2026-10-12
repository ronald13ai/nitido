// The strip's figures: frames shown and dropped as the view reports them (`framePresented`, `frameDropped`), and
// the snapshot taken every 250 ms, with the viewer's RTT (`refreshSnapshot`); and the first drawable shown, which lifts
// the picture's cover (`frameShown`).

import QuartzCore
import NitidoCore
import NitidoLink
import os

private let log = Logger(subsystem: "ai.ronar.nitido", category: "share")

extension ShareModel {
    /// The strip's figures, every 250 ms (`beginSession`): the viewer's newest RTT and the frames the capture stream
    /// let go are recorded, then the snapshot the strip shows is taken.
    func refreshSnapshot(now: CFTimeInterval) {
        // Each pong once: this loop runs twice as often as pings go out.
        if let rtt = link?.lastRTTSample, rtt.at != rttRecordedAt { rttRecordedAt = rtt.at; telemetry.recordRTT(ms: rtt.ms, at: rtt.at) }
        // Frames the capture stream let go because the share had not taken the one before yet.
        for _ in 0..<(capture?.takeDroppedFrames() ?? 0) { telemetry.recordDrop(at: now) }
        snapshot = telemetry.snapshot(now: now)
        stripSnapshot = figures.apply(snapshot)
    }

    /// A frame reached the screen (`FrameSink.onPresented`): it counts towards the display rate and the
    /// capture-to-display latency, and clears the last render failure.
    func framePresented(captureNs: UInt64, at presentedAt: Double) {
        let latencyMs = (presentedAt - Double(captureNs) / 1e9) * 1000
        telemetry.recordDisplay(at: presentedAt)
        telemetry.recordLatency(ms: latencyMs, at: presentedAt)
        if latencyMs < 0 || latencyMs > 5_000, !reportedClockMismatch {
            // The strip shows the figure as it is; the log says what it means.
            reportedClockMismatch = true
            log.error("Capture and display clocks disagree: a frame shows \(latencyMs, format: .fixed(precision: 1), privacy: .public) ms after its capture time")
        }
        if renderFailure != nil { renderFailure = nil }
    }

    /// A drawable reached the screen (`FrameSink.onShown`), a captured frame or the held one drawn again: the first of a
    /// capture lifts the picture's cover. A first frame that came while the window was covered or minimized reaches the
    /// screen only as a redraw when it shows, and a still source sends no other (spec 11, M6, amended 2026-10-12). Counts
    /// towards nothing else: a redraw is not a display.
    func frameShown(at presentedAt: Double) {
        if awaitingFirstFrame { awaitingFirstFrame = false; firstFrameAt = presentedAt }
    }

    /// A frame that did not reach the screen (`FrameSink.onDropped`) counts as dropped, unless the view was hidden; one
    /// that failed to render says why over the picture (`renderFailure`).
    func frameDropped(_ drop: VideoView.Drop) {
        switch drop {
        case .hidden:
            return
        case .backlog, .noDrawable, .notPresented, .replaced:
            telemetry.recordDrop(at: CACurrentMediaTime())
        case .failed(let reason):
            telemetry.recordDrop(at: CACurrentMediaTime())
            if renderFailure != reason { renderFailure = reason }
        }
    }
}
