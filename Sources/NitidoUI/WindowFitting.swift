import SwiftUI
import AppKit

/// Sizing rules shared by the windows that show a picture: 1:1 when it fits, scaled down when it does not, never up.
enum Fit {
    /// The factor that fits `natural` inside `limit`: 1 when it already fits, below 1 otherwise.
    static func factor(natural: CGSize, limit: CGSize) -> CGFloat {
        guard natural.width > 0, natural.height > 0 else { return 1 }
        return max(0.01, min(1, limit.width / natural.width, limit.height / natural.height))
    }

    /// Room for a picture on a screen with `visibleFrame`, leaving space for the title bar, the strip and a margin.
    static func limit(visibleFrame: CGRect) -> CGSize {
        CGSize(width: visibleFrame.width - 40, height: visibleFrame.height - 120)
    }

    /// `natural` itself when it fits (so 1:1 stays exact), otherwise scaled down and rounded to whole points.
    static func size(natural: CGSize, limit: CGSize) -> CGSize {
        let f = factor(natural: natural, limit: limit)
        guard f < 1 else { return natural }
        return CGSize(width: (natural.width * f).rounded(.down), height: (natural.height * f).rounded(.down))
    }

    /// `frame` moved, not resized, so it lies inside `visible`. A frame larger than `visible` keeps its
    /// top-left corner (title bar) inside it.
    static func constrained(_ frame: CGRect, in visible: CGRect) -> CGRect {
        var f = frame
        if f.width <= visible.width {
            f.origin.x = min(max(f.minX, visible.minX), visible.maxX - f.width)
        } else {
            f.origin.x = visible.minX
        }
        if f.height <= visible.height {
            f.origin.y = min(max(f.minY, visible.minY), visible.maxY - f.height)
        } else {
            f.origin.y = visible.maxY - f.height
        }
        return f
    }
}

/// Keeps the hosting window inside its screen's visible frame every time it changes size, so growing to a
/// large share or shrinking back to Welcome never leaves it partly or wholly off-screen.
struct KeepWindowOnScreen: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowKeeperView { WindowKeeperView() }
    func updateNSView(_ view: WindowKeeperView, context: Context) {}
}

final class WindowKeeperView: NSView {
    private weak var observed: NSWindow?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observed {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResizeNotification, object: observed)
        }
        observed = window
        guard let window else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidResize(_:)),
                                               name: NSWindow.didResizeNotification, object: window)
        keepOnScreen()
    }

    @objc private func windowDidResize(_ note: Notification) { keepOnScreen() }

    private func keepOnScreen() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let fitted = Fit.constrained(window.frame, in: screen.visibleFrame)
        if fitted.origin != window.frame.origin { window.setFrameOrigin(fitted.origin) }
    }
}
