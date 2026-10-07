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
    public func remoteCursor(_ c: Cursor, name: String) { canvas?.showRemoteCursor(c, name: name) }

    // Commands
    public func undoLocal() {
        guard let id = document.undoLastLocal() else { return }
        canvas?.remove(id: id, duration: 0.15)
        onOutgoing?(.undo(strokeId: id))
    }
    public func clearLocal() { document.clear(); canvas?.removeAll(); onOutgoing?(.clear) }

    /// Called 30 times a second by the canvas: starts fades and drops finished strokes.
    func tick() {
        let now = CACurrentMediaTime()
        for s in document.strokes where s.endedAt != nil && document.opacity(of: s, now: now) < 1 { canvas?.fade(id: s.id, duration: document.fadeDuration) }
        document.prune(now: now)
    }
}

/// Transparent AppKit view over the video: draws strokes as filled variable-width ribbons, one layer per stroke.
public final class InkCanvasView: NSView {
    unowned let controller: InkController
    private var layers: [UInt32: CAShapeLayer] = [:]
    private var fading: Set<UInt32> = []
    private var activeId: UInt32?
    private var strokeStart: Double = 0
    private var lastPoint: StrokePoint?
    private var timer: Timer?
    private let cursorDot = CALayer()
    private let cursorLabel = CATextLayer()

    init(controller: InkController) {
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        cursorDot.backgroundColor = NSColor(srgbRed: 201 / 255, green: 168 / 255, blue: 106 / 255, alpha: 1).cgColor
        cursorDot.cornerRadius = 5; cursorDot.bounds = CGRect(x: 0, y: 0, width: 10, height: 10); cursorDot.opacity = 0
        cursorLabel.fontSize = 10; cursorLabel.foregroundColor = NSColor(srgbRed: 243 / 255, green: 227 / 255, blue: 186 / 255, alpha: 1).cgColor
        cursorLabel.contentsScale = 2; cursorLabel.opacity = 0; cursorLabel.alignmentMode = .left
        layer?.addSublayer(cursorDot); layer?.addSublayer(cursorLabel)
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.controller.tick() }
        }
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    isolated deinit { timer?.invalidate() }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }

    private func normalized(_ event: NSEvent) -> StrokePoint {
        let p = convert(event.locationInWindow, from: nil)
        let pressure = event.type == .leftMouseDragged || event.type == .leftMouseDown ? max(0.2, Float(event.pressure == 0 ? 1 : event.pressure)) : 1
        return StrokePoint(x: Float(p.x / max(bounds.width, 1)), y: Float(p.y / max(bounds.height, 1)), pressure: pressure,
                           tMs: UInt32(max(0, (CACurrentMediaTime() - strokeStart) * 1000)))
    }

    public override func mouseDown(with event: NSEvent) {
        strokeStart = CACurrentMediaTime()
        let p = normalized(event)
        activeId = controller.beginLocal(p)
        lastPoint = p
    }
    public override func mouseDragged(with event: NSEvent) {
        guard let id = activeId else { return }
        let p = normalized(event)
        controller.appendLocal(id, [p]); lastPoint = p
        controller.cursorMoved(Cursor(x: p.x, y: p.y, visible: true))
    }
    public override func mouseUp(with event: NSEvent) {
        guard let id = activeId else { return }
        controller.endLocal(id); activeId = nil
    }
    public override func mouseMoved(with event: NSEvent) {
        let p = normalized(event); controller.cursorMoved(Cursor(x: p.x, y: p.y, visible: true))
    }
    public override func mouseExited(with event: NSEvent) { controller.cursorMoved(Cursor(x: 0, y: 0, visible: false)) }
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
        let color = stroke.isRemote ? NSColor(srgbRed: 243 / 255, green: 227 / 255, blue: 186 / 255, alpha: 1) : NSColor(srgbRed: 201 / 255, green: 168 / 255, blue: 106 / 255, alpha: 1)
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

    func fade(id: UInt32, duration: Double) {
        guard !fading.contains(id), let l = layers[id] else { return }
        fading.insert(id)
        animateOpacity(l, to: 0, duration: duration) { [weak self] in self?.layers[id]?.removeFromSuperlayer(); self?.layers[id] = nil; self?.fading.remove(id) }
    }
    func remove(id: UInt32, duration: Double) { fade(id: id, duration: duration) }
    func removeAll() { layers.keys.forEach { remove(id: $0, duration: 0.15) } }

    private func animateOpacity(_ l: CALayer, to value: Float, duration: Double, completion: @escaping () -> Void) {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = l.presentation()?.opacity ?? l.opacity; a.toValue = value
        a.duration = reduce ? duration * 0.5 : duration
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
    public func makeNSView(context: Context) -> InkCanvasView { let v = InkCanvasView(controller: controller); controller.canvas = v; return v }
    public func updateNSView(_ view: InkCanvasView, context: Context) { controller.canvas = view }
}
