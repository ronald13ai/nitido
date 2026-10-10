import SwiftUI
import AppKit
import QuartzCore
import NitidoCore

/// Owns the ink document, allocates ids, and keeps the canvas in sync. One per window.
@MainActor
public final class InkController {
    public private(set) var document = InkDocument()
    public let role: Role
    public var onOutgoing: ((Message) -> Void)?
    weak var canvas: InkCanvasView?

    public init(role: Role) { self.role = role }

    // Local input (called by the canvas)
    func beginLocal(_ p: StrokePoint) -> UInt32 {
        let id = document.allocateId(role: role)
        let m = StrokeMessage(strokeId: id, phase: .begin, color: .gold, baseWidth: 4, points: [p])
        document.apply(m, isRemote: false, now: CACurrentMediaTime())
        canvas?.update(document.strokes.last!)
        onOutgoing?(.stroke(m))
        return id
    }
    func appendLocal(_ id: UInt32, _ points: [StrokePoint]) {
        let m = StrokeMessage(strokeId: id, phase: .append, color: .gold, baseWidth: 4, points: points)
        document.apply(m, isRemote: false, now: CACurrentMediaTime())
        if let s = document.strokes.first(where: { $0.id == id }) { canvas?.update(s) }
        onOutgoing?(.stroke(m))
    }
    func endLocal(_ id: UInt32) {
        let m = StrokeMessage(strokeId: id, phase: .end, color: .gold, baseWidth: 4, points: [])
        document.apply(m, isRemote: false, now: CACurrentMediaTime())
        onOutgoing?(.stroke(m))
    }
    func cursorMoved(_ c: Cursor) { onOutgoing?(.cursor(c)) }

    // Remote input (wired in Task 13)
    public func applyRemote(_ m: StrokeMessage) {
        document.apply(m, isRemote: true, now: CACurrentMediaTime())
        if let s = document.strokes.first(where: { $0.id == m.strokeId }) { canvas?.update(s) }
    }
    public func undoRemote(id: UInt32) { document.remove(id: id); canvas?.remove(id: id, duration: 0.15) }
    public func clearRemote() { document.clear(); canvas?.removeAll() }
    /// The peer's link dropped: its strokes still being drawn will get no `.end`, so they end now and fade in four seconds.
    public func endRemoteStrokes() { document.endRemoteStrokes(now: CACurrentMediaTime()) }
    public func remoteCursor(_ c: Cursor, name: String) { canvas?.showRemoteCursor(c, name: name) }

    // Commands
    public func undoLocal() {
        guard let id = document.undoLastLocal() else { return }
        canvas?.remove(id: id, duration: 0.15)
        onOutgoing?(.undo(strokeId: id))
    }
    public func clearLocal() { document.clear(); canvas?.removeAll(); onOutgoing?(.clear) }

    /// How many times the canvas ticked this controller. Internal for tests.
    private(set) var ticks = 0
    /// Called 30 times a second by the canvas: starts fades and drops finished strokes.
    func tick() {
        ticks += 1
        let now = CACurrentMediaTime()
        for s in document.strokes where s.endedAt != nil && document.opacity(of: s, now: now) < 1 { canvas?.fade(id: s.id, duration: document.fadeDuration) }
        document.prune(now: now)
    }
}

/// Transparent AppKit view over the video: draws strokes as filled variable-width ribbons, one layer per stroke.
public final class InkCanvasView: NSView {
    /// The controller whose strokes the canvas draws and takes. Weak: SwiftUI keeps the canvas when the share or view
    /// on screen is replaced by a new one and hands it the new controller (`attach`), while the old controller goes
    /// with its model. Held unowned, the canvas's next tick read the old one after it was gone and aborted the app
    /// (`swift_abortRetainUnowned`, the evening two-Mac test of 2026-10-09: a share stopped, then a new one started).
    private(set) weak var controller: InkController?
    private var layers: [UInt32: CAShapeLayer] = [:]
    private var fading: Set<UInt32> = []
    private var activeId: UInt32?
    private var strokeStart: Double = 0
    private var lastPoint: StrokePoint?
    /// The 30 Hz tick that starts fades and drops finished strokes (`InkController.tick`): scheduled while the canvas
    /// is in a window, invalidated when it leaves it or goes. Internal so a test can fire it.
    private(set) var tickTimer: Timer?
    private let cursorDot = CALayer()
    private let cursorLabel = CATextLayer()

    init(controller: InkController) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        cursorDot.backgroundColor = Theme.CanvasColors.gold.cgColor
        cursorDot.cornerRadius = 5; cursorDot.bounds = CGRect(x: 0, y: 0, width: 10, height: 10); cursorDot.opacity = 0
        cursorLabel.fontSize = 10; cursorLabel.foregroundColor = Theme.CanvasColors.cream.cgColor
        cursorLabel.contentsScale = 2; cursorLabel.opacity = 0; cursorLabel.alignmentMode = .left
        layer?.addSublayer(cursorDot); layer?.addSublayer(cursorLabel)
        attach(to: controller)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    isolated deinit { tickTimer?.invalidate() }

    /// Draws and takes `controller`'s strokes from now on (`InkOverlay`): the canvas SwiftUI kept is handed the
    /// controller of the share or view on screen now. The strokes drawn for the controller before are taken off, and
    /// that controller no longer points at this canvas. That holds when the controller before is gone already (the
    /// canvas holds it weakly, and the old model can go before SwiftUI hands over the new one): only its tick would
    /// have faded those strokes, and the stroke under way and the fades in progress were its too.
    func attach(to controller: InkController) {
        if self.controller !== controller {
            if let old = self.controller, old.canvas === self { old.canvas = nil }
            layers.values.forEach { $0.removeFromSuperlayer() }
            layers = [:]; fading = []; activeId = nil; lastPoint = nil
        }
        self.controller = controller
        controller.canvas = self
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopTicking() } else { startTicking() }
    }

    /// Schedules the tick, unless it is scheduled already. Internal so a test can start it without a window.
    func startTicking() {
        guard tickTimer == nil else { return }
        // Weak: the timer's run loop holds the closure, and must not keep a canvas that left its window alive.
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func stopTicking() { tickTimer?.invalidate(); tickTimer = nil }

    /// One tick, for the controller if it is still there.
    private func tick() { controller?.tick() }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }

    private func normalized(_ event: NSEvent) -> StrokePoint {
        let p = convert(event.locationInWindow, from: nil)
        let pressure = event.type == .leftMouseDragged || event.type == .leftMouseDown ? max(0.2, Float(event.pressure == 0 ? 1 : event.pressure)) : 1
        return StrokePoint(x: Float(p.x / max(bounds.width, 1)), y: Float(p.y / max(bounds.height, 1)), pressure: pressure,
                           tMs: Self.elapsedMs(since: strokeStart, now: CACurrentMediaTime()))
    }

    /// Milliseconds from `start` to `now`, clamped to `0...UInt32.max`. Before the first stroke `start` is 0, so a
    /// hover stamps the awake uptime, which passes `UInt32.max` ms after about 49.7 days; converting that unclamped
    /// would trap.
    nonisolated static func elapsedMs(since start: Double, now: Double) -> UInt32 {
        let ms = (now - start) * 1000
        guard !ms.isNaN else { return 0 }
        return UInt32(min(Double(UInt32.max), max(0, ms)))
    }

    public override func mouseDown(with event: NSEvent) {
        guard let controller else { return }
        strokeStart = CACurrentMediaTime()
        let p = normalized(event)
        activeId = controller.beginLocal(p)
        lastPoint = p
    }
    public override func mouseDragged(with event: NSEvent) {
        guard let id = activeId, let controller else { return }
        let p = normalized(event)
        controller.appendLocal(id, [p]); lastPoint = p
        controller.cursorMoved(Cursor(x: p.x, y: p.y, visible: true))
    }
    public override func mouseUp(with event: NSEvent) {
        guard let id = activeId else { return }
        controller?.endLocal(id); activeId = nil
    }
    public override func mouseMoved(with event: NSEvent) {
        let p = normalized(event); controller?.cursorMoved(Cursor(x: p.x, y: p.y, visible: true))
    }
    public override func mouseExited(with event: NSEvent) {
        controller?.cursorMoved(Cursor(x: 0, y: 0, visible: false))
    }
    public override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    // Rendering
    func update(_ stroke: Stroke) {
        let shape = layers[stroke.id] ?? makeLayer(for: stroke)
        shape.path = ribbon(for: stroke)
    }

    private func makeLayer(for stroke: Stroke) -> CAShapeLayer {
        let l = CAShapeLayer()
        let color = stroke.isRemote ? Theme.CanvasColors.cream : Theme.CanvasColors.gold
        l.fillColor = color.cgColor; l.strokeColor = color.cgColor; l.lineWidth = 1; l.lineJoin = .round; l.lineCap = .round
        l.contentsScale = window?.backingScaleFactor ?? 2
        layer?.insertSublayer(l, below: cursorDot)
        layers[stroke.id] = l
        return l
    }

    /// Variable-width ribbon: the smoothed centerline offset by half the per-point width on each side.
    private func ribbon(for stroke: Stroke) -> CGPath {
        let path = CGMutablePath()
        let w = bounds.width, h = bounds.height
        let pts = stroke.points
        guard let first = pts.first else { return path }
        if pts.count == 1 {
            let r = CGFloat(stroke.baseWidth) * 0.6
            path.addEllipse(in: CGRect(x: CGFloat(first.x) * w - r, y: CGFloat(first.y) * h - r, width: 2 * r, height: 2 * r))
            return path
        }
        var widths: [CGFloat] = []
        var smoothed: Float = stroke.baseWidth
        for i in 0..<pts.count {
            let speed = i == 0 ? 0 : InkGeometry.speed(from: pts[i - 1], to: pts[i])
            let target = InkGeometry.width(base: stroke.baseWidth * pts[i].pressure, speedPerMs: speed)
            smoothed += (target - smoothed) * 0.3
            widths.append(CGFloat(smoothed))
        }
        let center = InkGeometry.smooth(pts, segments: 6).map { CGPoint(x: CGFloat($0.x) * w, y: CGFloat($0.y) * h) }
        guard center.count > 1 else { return path }
        var left: [CGPoint] = [], right: [CGPoint] = []
        for i in 0..<center.count {
            let a = center[max(0, i - 1)], b = center[min(center.count - 1, i + 1)]
            var nx = -(b.y - a.y), ny = b.x - a.x
            let len = max(hypot(nx, ny), 0.0001); nx /= len; ny /= len
            let half = widths[min(widths.count - 1, i * (widths.count - 1) / max(1, center.count - 1))] / 2
            left.append(CGPoint(x: center[i].x + nx * half, y: center[i].y + ny * half))
            right.append(CGPoint(x: center[i].x - nx * half, y: center[i].y - ny * half))
        }
        path.move(to: left[0]); left.dropFirst().forEach { path.addLine(to: $0) }
        right.reversed().forEach { path.addLine(to: $0) }
        path.closeSubpath()
        return path
    }

    /// Fades the stroke's layer out and then takes it off. The end of the fade goes by the layer, not the id alone: a
    /// fade can end after `attach` handed the canvas a new controller, whose ids start over, so by then the id can name
    /// the new share's stroke.
    func fade(id: UInt32, duration: Double) {
        guard !fading.contains(id), let l = layers[id] else { return }
        fading.insert(id)
        animateOpacity(l, to: 0, duration: duration) { [weak self] in
            guard let self, layers[id] === l else { return }
            l.removeFromSuperlayer(); layers[id] = nil; fading.remove(id)
        }
    }
    func remove(id: UInt32, duration: Double) { fade(id: id, duration: duration) }
    func removeAll() { layers.keys.forEach { remove(id: $0, duration: 0.15) } }

    /// An opacity fade over `duration`, Reduce Motion or not: spec 11 takes away scale and the ring, and keeps fades as
    /// they are.
    private func animateOpacity(_ l: CALayer, to value: Float, duration: Double, completion: @escaping () -> Void) {
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = l.presentation()?.opacity ?? l.opacity; a.toValue = value
        a.duration = duration
        a.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
        l.opacity = value
        l.add(a, forKey: "opacity")
        CATransaction.commit()
    }

    func showRemoteCursor(_ c: Cursor, name: String) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        cursorDot.position = CGPoint(x: CGFloat(c.x) * bounds.width, y: CGFloat(c.y) * bounds.height)
        cursorLabel.string = name
        cursorLabel.frame = CGRect(x: cursorDot.position.x + 9, y: cursorDot.position.y - 7, width: 160, height: 14)
        CATransaction.commit()
        let target: Float = c.visible ? 1 : 0
        if cursorDot.opacity != target { cursorDot.opacity = target; cursorLabel.opacity = target }
    }
}

public struct InkOverlay: NSViewRepresentable {
    public let controller: InkController
    public init(controller: InkController) { self.controller = controller }
    public func makeNSView(context: Context) -> InkCanvasView { InkCanvasView(controller: controller) }
    /// SwiftUI keeps the canvas when the model on screen changes: it draws for the controller it is handed now.
    public func updateNSView(_ view: InkCanvasView, context: Context) { view.attach(to: controller) }
}
