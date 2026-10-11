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

    /// The smallest picture area the Share and View windows take, in points. A small shared window (a palette, a
    /// calculator, a 200 by 100 px utility) made a window as small as its picture: the pairing panel and the codec loop
    /// panel then overlapped and spilled past its edges, hiding the code, and a failure card's buttons were cut off.
    /// 480 pt holds the loop panel (220 pt) beside a pairing panel with a name of thirty characters, 16 pt from the edges
    /// and 8 pt apart; 260 pt holds a failure card with a few lines.
    static let minimumArea = CGSize(width: 480, height: 260)

    /// The picture area for a picture of `picture` points: its size to the whole point, at least `minimumArea`.
    static func area(for picture: CGSize) -> CGSize {
        CGSize(width: max(picture.width.rounded(.up), minimumArea.width), height: max(picture.height.rounded(.up), minimumArea.height))
    }

    /// Where a picture of `picture` points sits in `area`: centred on the background, at whole points, so a 1:1 picture
    /// stays on the pixel grid; at the top left when the area is the picture's own (a half-point picture keeps its exact
    /// size there, with at most a point of background).
    static func origin(of picture: CGSize, in area: CGSize) -> CGPoint {
        CGPoint(x: max(0, ((area.width - picture.width) / 2).rounded(.down)), y: max(0, ((area.height - picture.height) / 2).rounded(.down)))
    }

    /// The strip's size figure: pixels and display scale, and the scale the picture is shown at when it is fitted
    /// below 1:1 (spec 17), as a whole percentage. "·" before the first frame.
    static func resolutionLabel(pixelSize: CGSize, scale: CGFloat, factor: CGFloat) -> String {
        guard pixelSize != .zero else { return "·" }
        let base = "\(Int(pixelSize.width))×\(Int(pixelSize.height)) @\(Int(scale))x"
        return factor < 1 ? "\(base) · \(Int((factor * 100).rounded()))%" : base
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
    /// The visible frame the window is kept inside: its screen's, or the main screen's while it is on none. Internal so a
    /// test can give it one, and not depend on which displays the Mac has or which of them is main.
    var visibleFrame: (NSWindow) -> CGRect? = { ($0.screen ?? NSScreen.main)?.visibleFrame }

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
        guard let window, let visible = visibleFrame(window) else { return }
        let fitted = Fit.constrained(window.frame, in: visible)
        if fitted.origin != window.frame.origin { window.setFrameOrigin(fitted.origin) }
    }
}
