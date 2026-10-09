import QuartzCore
@testable import NitidoUI

/// Stands in for a visible window behind a `VideoView`: put in as the view's pacer host (`show(_:)`), it says the view
/// can show frames, counts every frame drawn instead of going to Metal, and gives each drawable back at once as shown.
/// Drops and presentations go on to the view, so a model hears them as it would from a window on screen. A view
/// outside any window cannot show frames, and a model test needs one that can.
@MainActor
final class ShowingDisplay: FrameDrawing {
    var canShowFrames = true
    var drawableCount = 3
    var refreshRate: Double = 60
    /// The capture time of every frame drawn, in order.
    private(set) var drawn: [UInt64] = []
    private weak var view: VideoView?

    /// Puts this display behind `view`. The pacer holds its host weakly: the test keeps this one.
    func show(_ view: VideoView) {
        self.view = view
        view.pacer.host = self
        view.pacer.drawableSize = CGSize(width: 640, height: 360)
    }

    func render(_ frame: FramePacer.Frame, kind: FramePacer.Kind) -> VideoView.Drop? {
        drawn.append(frame.captureHostTimeNs)
        let captureNs = frame.captureHostTimeNs
        Task { @MainActor [weak self] in
            self?.view?.pacer.drawableReturned(kind: kind, captureHostTimeNs: captureNs, presentedAt: CACurrentMediaTime())
        }
        return nil
    }

    func framePresented(captureHostTimeNs: UInt64, at presentedAt: Double) {
        view?.framePresented(captureHostTimeNs: captureHostTimeNs, at: presentedAt)
    }

    func frameDropped(_ drop: VideoView.Drop) { view?.frameDropped(drop) }
}
