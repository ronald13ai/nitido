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

    // Remote input. Everything here comes from the other Mac, which holds the code but is not trusted further: its
    // floats can be any bit pattern (a NaN position made Core Animation raise `CALayerInvalidGeometry` and abort the
    // app), its ids any number, its strokes any length. The limits below keep a hostile peer from crashing this side,
    // freezing it or taking over this side's strokes.

    /// At most this many of the peer's strokes are being drawn at once (begun, not ended); a `.begin` beyond it is
    /// dropped. Ended strokes fade and go on their own.
    static let maxRemoteStrokesInFlight = 64
    /// At most this many points in one of the peer's strokes; points beyond it are dropped (the stroke stops growing).
    static let maxPointsPerStroke = 10_000
    /// The peer's stroke widths are kept within this range, in points; a width that is not a number takes the default.
    static let remoteWidths: ClosedRange<Float> = 1...32

    /// The peer's ids have the peer's parity (`InkDocument.allocateId`: the sharer's even, the viewer's odd). One with
    /// this side's parity names, or would take over, one of this side's own strokes: it is ignored.
    private func isPeers(_ id: UInt32) -> Bool { id % 2 == (role == .share ? 1 : 0) }

    public func applyRemote(_ m: StrokeMessage) {
        guard isPeers(m.strokeId) else { return }
        // What is known of the stroke, without its points: a copy of the stroke held across `apply` would make the append
        // copy every point it has, so each point of a long stroke would cost more than the one before.
        let existing = document.strokes.first { $0.id == m.strokeId }.map { (isRemote: $0.isRemote, count: $0.points.count) }
        var points = m.points.compactMap(Self.sanitized)
        switch m.phase {
        case .begin:
            let inFlight = document.strokes.filter { $0.isRemote && $0.endedAt == nil && $0.id != m.strokeId }.count
            guard inFlight < Self.maxRemoteStrokesInFlight else { return }
            points = Array(points.prefix(Self.maxPointsPerStroke))
        case .append:
            guard let existing, existing.isRemote else { return }
            points = Array(points.prefix(max(0, Self.maxPointsPerStroke - existing.count)))
            guard !points.isEmpty else { return }
        case .end:
            guard existing?.isRemote ?? false else { return }
        }
        let width = m.baseWidth.isFinite ? min(max(m.baseWidth, Self.remoteWidths.lowerBound), Self.remoteWidths.upperBound) : 4
        document.apply(StrokeMessage(strokeId: m.strokeId, phase: m.phase, color: m.color, baseWidth: width, points: points),
                       isRemote: true, now: CACurrentMediaTime())
        if let s = document.strokes.first(where: { $0.id == m.strokeId }) { canvas?.update(s) }
    }

    /// A point of the peer's within the picture: x and y clamped to 0...1, pressure to 0...1; nil for one with a value
    /// that is not a number.
    nonisolated static func sanitized(_ p: StrokePoint) -> StrokePoint? {
        guard p.x.isFinite, p.y.isFinite, p.pressure.isFinite else { return nil }
        return StrokePoint(x: min(max(p.x, 0), 1), y: min(max(p.y, 0), 1), pressure: min(max(p.pressure, 0), 1), tMs: p.tMs)
    }

    /// The peer's undo, seen here: the person who did not do it sees what went, the stroke rewinding from its end
    /// (spec 11, M15).
    public func undoRemote(id: UInt32) {
        guard isPeers(id), let stroke = document.strokes.first(where: { $0.id == id && $0.isRemote }) else { return }
        canvas?.rewind(stroke)
        document.remove(id: id)
    }
    /// The peer's clear, seen here: every stroke fades over 200 ms (no rewinding: many at once would be noise).
    public func clearRemote() { document.clear(); canvas?.fadeAll() }
    /// The peer's link dropped: its strokes still being drawn will get no `.end`, so they end now and fade in four seconds,
    /// and its cursor, which will not move again, goes.
    public func endRemoteStrokes() { document.endRemoteStrokes(now: CACurrentMediaTime()); hideRemoteCursor() }
    /// The peer's cursor goes (its link dropped or closed).
    public func hideRemoteCursor() { canvas?.hideRemoteCursor() }
    /// The peer's cursor, inside the picture. A position that is not a number is dropped, and the dot stays where it was.
    public func remoteCursor(_ c: Cursor, name: String) {
        guard c.x.isFinite, c.y.isFinite else { return }
        canvas?.showRemoteCursor(Cursor(x: min(max(c.x, 0), 1), y: min(max(c.y, 0), 1), visible: c.visible), name: name)
    }

    // Commands. ⌘Z and ⌘⌫ are keyboard actions on this Mac, so they take effect at once (the other Mac animates them).
    public func undoLocal() {
        guard let id = document.undoLastLocal() else { return }
        canvas?.removeNow(id: id)
        onOutgoing?(.undo(strokeId: id))
    }
    public func clearLocal() { document.clear(); canvas?.removeAllNow(); onOutgoing?(.clear) }

    /// How many times the canvas ticked this controller. Internal for tests.
    private(set) var ticks = 0
    /// Called 30 times a second by the canvas while it has strokes: starts fades and drops finished strokes.
    func tick() {
        ticks += 1
        let now = CACurrentMediaTime()
        for s in document.strokes where s.endedAt != nil && document.opacity(of: s, now: now) < 1 {
            canvas?.fade(id: s.id, duration: document.fadeDuration, passive: true)
        }
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
    private var layers: [UInt32: StrokeLayers] = [:]
    private var fading: Set<UInt32> = []
    private var activeId: UInt32?
    private var strokeStart: Double = 0
    private var lastPoint: StrokePoint?
    /// The 30 Hz tick that starts fades and drops finished strokes (`InkController.tick`): scheduled while the canvas
    /// is in a window and has strokes to fade, invalidated once the last one is gone, or when the canvas leaves its
    /// window or goes. Spec 11: nothing but the picture and the sparkline works on every frame, and a session without
    /// ink is most of them. Internal so a test can fire it.
    private(set) var tickTimer: Timer?
    private let cursorDot = CALayer()
    /// The peer's name beside its cursor, on a solid pill of the surface with a hairline, so it reads on a white document
    /// as on a dark one, with nothing of the document showing through.
    private let cursorPill = CALayer()
    /// The peer's cursor as it last came, in picture units, and its name: placed again when the canvas changes size.
    private var lastRemoteCursor: (cursor: Cursor, name: String)?
    /// This side's pointer is over the picture and has gone out to the peer as a visible cursor.
    private var pointerShown = false
    /// The window whose key and miniaturize notifications the canvas observes (`viewDidMoveToWindow`).
    private weak var observedWindow: NSWindow?
    private let cursorLabel = CATextLayer()
    private static let cursorFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    /// Reduce Motion, as SwiftUI says it (`InkOverlay`): a rewind becomes a fade.
    var reduceMotion = false

    /// The ink's motion (spec 11, M15), all of it Core Animation on the render server.
    enum Motion {
        /// The peer's undo: the stroke rewinds from its end over 180 ms, fading over the last 80.
        static let rewind = Theme.Motion.Curve(Theme.Motion.strongEaseInOut, 0.18)
        static let rewindFade: Double = 0.08
        /// The peer's clear: every stroke fades over 200 ms.
        static let clear = Theme.Motion.enter.over(0.2)
        /// Under Reduce Motion the rewind is a 150 ms fade.
        static let reducedRewind = Theme.Motion.reducedFade
        /// The peer's cursor coming (120 ms) and going (200 ms).
        static let cursorIn = Theme.Motion.enter.over(0.12)
        static let cursorOut = Theme.Motion.Curve(Theme.Motion.easeOut, 0.2)
    }

    init(controller: InkController) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        cursorDot.backgroundColor = Theme.CanvasColors.gold.cgColor
        cursorDot.cornerRadius = 5; cursorDot.bounds = CGRect(x: 0, y: 0, width: 10, height: 10); cursorDot.opacity = 0
        cursorDot.shadowColor = NSColor.black.cgColor; cursorDot.shadowOpacity = 0.35; cursorDot.shadowRadius = 1.5; cursorDot.shadowOffset = .zero
        cursorPill.backgroundColor = Theme.CanvasColors.surface.cgColor
        cursorPill.borderColor = Theme.CanvasColors.hairline.cgColor; cursorPill.borderWidth = 1
        cursorPill.cornerRadius = 6; cursorPill.opacity = 0
        cursorLabel.font = Self.cursorFont; cursorLabel.fontSize = 11; cursorLabel.foregroundColor = Theme.CanvasColors.cream.cgColor
        cursorLabel.alignmentMode = .left; cursorLabel.truncationMode = .end
        cursorPill.addSublayer(cursorLabel)
        layer?.addSublayer(cursorDot); layer?.addSublayer(cursorPill)
        applyBackingScale()
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
            layers.values.forEach { $0.shape.removeFromSuperlayer() }
            layers = [:]; fading = []; activeId = nil; lastPoint = nil
        }
        self.controller = controller
        controller.canvas = self
        if window != nil, hasStrokes { startTicking() }
    }

    /// The controller has strokes the tick must fade or drop.
    private var hasStrokes: Bool { controller.map { !$0.document.strokes.isEmpty } ?? false }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyBackingScale()
        if window == nil || !hasStrokes { stopTicking() } else { startTicking() }
        let center = NotificationCenter.default
        if let observedWindow {
            center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: observedWindow)
            center.removeObserver(self, name: NSWindow.didMiniaturizeNotification, object: observedWindow)
        }
        observedWindow = window
        if let window {
            center.addObserver(self, selector: #selector(windowStoppedTracking(_:)), name: NSWindow.didResignKeyNotification, object: window)
            center.addObserver(self, selector: #selector(windowStoppedTracking(_:)), name: NSWindow.didMiniaturizeNotification, object: window)
        }
    }

    /// The window stopped being key (⌘Tab, a click in another app) or went to the Dock while the pointer was over the
    /// picture: the tracking area goes inactive, AppKit sends no `mouseExited`, and the peer would go on showing this
    /// side's dot where the pointer last was. It is hidden now.
    @objc private func windowStoppedTracking(_ note: Notification) { hidePointerFromPeer() }

    private func hidePointerFromPeer() {
        guard pointerShown else { return }
        pointerShown = false
        controller?.cursorMoved(Cursor(x: 0, y: 0, visible: false))
    }

    /// A new size (the window moved to a display of another scale, the capture resized, the screen's room changed): the
    /// strokes and the peer's cursor, kept in picture units, are laid out again, so they stay on what they mark.
    public override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { relayout() }
    }

    /// Every stroke's ribbon and halo, and the peer's cursor, at the current size. Internal so a test can call it.
    func relayout() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for stroke in controller?.document.strokes ?? [] {
            guard let entry = layers[stroke.id] else { continue }
            draw(stroke, on: entry, again: true)
        }
        if let last = lastRemoteCursor { placeRemoteCursor(last.cursor, name: last.name) }
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyBackingScale()
    }

    /// The window's scale for every layer that draws text or a path, so they stay sharp on any display.
    private func applyBackingScale() {
        let scale = window?.backingScaleFactor ?? 2
        cursorLabel.contentsScale = scale
        cursorPill.contentsScale = scale
        layers.values.forEach { $0.contentsScale = scale }
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

    /// One tick, for the controller if it is still there; the last stroke gone (or the controller), the tick stops
    /// until the next stroke (`update`).
    private func tick() {
        controller?.tick()
        if !hasStrokes { stopTicking() }
    }

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
        controller.cursorMoved(Cursor(x: p.x, y: p.y, visible: true)); pointerShown = true
    }
    public override func mouseUp(with event: NSEvent) {
        guard let id = activeId else { return }
        controller?.endLocal(id); activeId = nil
    }
    public override func mouseMoved(with event: NSEvent) {
        let p = normalized(event); controller?.cursorMoved(Cursor(x: p.x, y: p.y, visible: true)); pointerShown = true
    }
    public override func mouseExited(with event: NSEvent) {
        pointerShown = false
        controller?.cursorMoved(Cursor(x: 0, y: 0, visible: false))
    }
    public override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    // Rendering

    /// One stroke's layers. `shape` is the stroke's layer on the canvas, the one that fades and goes. While the ribbon is
    /// all live it draws the ribbon and its halo, as every stroke did. Once a long stroke has frozen pieces
    /// (`RibbonOutline`), `shape` draws nothing itself: `halos` holds a halo per piece and `fills` the pieces in the
    /// stroke's colour, the live part's last in each, and every halo lies under every fill, as one shape's halo lies under
    /// its fill, so a piece's halo never shades the piece before it at their joint.
    @MainActor
    private final class StrokeLayers {
        let shape: CAShapeLayer
        /// The peer's stroke, in cream; this side's is gold.
        let remote: Bool
        var outline: RibbonOutline?
        var pieces: (halos: CALayer, fills: CALayer, liveHalo: CAShapeLayer, liveFill: CAShapeLayer)?
        init(shape: CAShapeLayer, remote: Bool) { self.shape = shape; self.remote = remote }

        /// The window's scale, for the stroke's layer and every piece.
        var contentsScale: CGFloat {
            get { shape.contentsScale }
            set {
                shape.contentsScale = newValue
                pieces?.halos.sublayers?.forEach { $0.contentsScale = newValue }
                pieces?.fills.sublayers?.forEach { $0.contentsScale = newValue }
            }
        }
    }

    func update(_ stroke: Stroke) {
        let entry = layers[stroke.id] ?? makeLayers(for: stroke)
        draw(stroke, on: entry)
        if window != nil { startTicking() }
    }

    /// Draws `stroke` on its layers at the canvas's size: only the live part its new points changed, the frozen pieces
    /// staying as they are (`RibbonOutline`). `again`, a new size, fewer points or a stroke begun again under the same id
    /// draws it all from the start. Pieces come and go with actions off, so none fades in or out.
    private func draw(_ stroke: Stroke, on entry: StrokeLayers, again: Bool = false) {
        let pts = stroke.points
        let fresh = again || pts.count < 2 || entry.outline.map {
            $0.size != bounds.size || $0.startedAt != stroke.startedAt || $0.pointCount > pts.count
        } ?? true
        var frozen: [CGPath] = []
        let live: CGPath
        if pts.count < 2 {
            entry.outline = nil
            live = dot(for: stroke)
        } else {
            if fresh { entry.outline = RibbonOutline(baseWidth: stroke.baseWidth, startedAt: stroke.startedAt, size: bounds.size) }
            // In place: a copy of the outline would make its widths copied on every point.
            frozen = entry.outline!.advance(to: pts)
            live = entry.outline!.livePath(pts)
        }
        let restructure = (fresh && entry.pieces != nil) || !frozen.isEmpty
        if restructure { CATransaction.begin(); CATransaction.setDisableActions(true) }
        defer { if restructure { CATransaction.commit() } }
        if fresh, let pieces = entry.pieces {
            pieces.halos.removeFromSuperlayer(); pieces.fills.removeFromSuperlayer()
            entry.pieces = nil
            entry.shape.shadowOpacity = Self.haloOpacity
        }
        if !frozen.isEmpty {
            let pieces = entry.pieces ?? makePieces(on: entry)
            for path in frozen {
                let halo = makeHalo(remote: entry.remote, scale: entry.contentsScale)
                halo.path = path; halo.shadowPath = path
                pieces.halos.insertSublayer(halo, below: pieces.liveHalo)
                let fill = CAShapeLayer()
                style(fill, remote: entry.remote, scale: entry.contentsScale)
                fill.path = path
                pieces.fills.insertSublayer(fill, below: pieces.liveFill)
            }
        }
        if let pieces = entry.pieces {
            pieces.liveFill.path = live
            pieces.liveHalo.path = live; pieces.liveHalo.shadowPath = live
        } else {
            entry.shape.path = live
            // The halo follows the ribbon; given its path, Core Animation does not work it out from the pixels each frame.
            entry.shape.shadowPath = live
        }
    }

    /// The halo's opacity and radius: soft and dark, so the cream, about 1.2:1 on a white document, and the gold, about
    /// 2.2:1, still read on the most common picture.
    private static let haloOpacity: Float = 0.35
    private static let haloRadius: CGFloat = 1.5

    /// A ribbon in gold (this side) or cream (the peer), with its halo.
    private func makeLayers(for stroke: Stroke) -> StrokeLayers {
        let l = CAShapeLayer()
        style(l, remote: stroke.isRemote, scale: window?.backingScaleFactor ?? 2)
        l.shadowColor = NSColor.black.cgColor; l.shadowOpacity = Self.haloOpacity; l.shadowRadius = Self.haloRadius; l.shadowOffset = .zero
        layer?.insertSublayer(l, below: cursorDot)
        let entry = StrokeLayers(shape: l, remote: stroke.isRemote)
        layers[stroke.id] = entry
        return entry
    }

    /// A ribbon's fill: the stroke's colour, edged with a 1 pt line of it, round joins and caps.
    private func style(_ l: CAShapeLayer, remote: Bool, scale: CGFloat) {
        let color = remote ? Theme.CanvasColors.cream : Theme.CanvasColors.gold
        l.fillColor = color.cgColor; l.strokeColor = color.cgColor; l.lineWidth = 1; l.lineJoin = .round; l.lineCap = .round
        l.contentsScale = scale
    }

    /// A piece's halo: the piece filled in the stroke's colour, without the edge line, with the halo of its path. The fill
    /// is there so the layer has content (Core Animation's own renderer draws no shadow for a layer that draws nothing),
    /// and the piece's fill layer, edge line and all, covers it whole.
    private func makeHalo(remote: Bool, scale: CGFloat) -> CAShapeLayer {
        let l = CAShapeLayer()
        style(l, remote: remote, scale: scale)
        l.strokeColor = nil
        l.shadowColor = NSColor.black.cgColor; l.shadowOpacity = Self.haloOpacity; l.shadowRadius = Self.haloRadius; l.shadowOffset = .zero
        return l
    }

    /// The stroke's layer stops drawing the ribbon itself and holds the pieces: the halos first, then the fills.
    private func makePieces(on entry: StrokeLayers) -> (halos: CALayer, fills: CALayer, liveHalo: CAShapeLayer, liveFill: CAShapeLayer) {
        let shape = entry.shape
        shape.path = nil; shape.shadowPath = nil; shape.shadowOpacity = 0
        let halos = CALayer(), fills = CALayer()
        shape.addSublayer(halos); shape.addSublayer(fills)
        let liveHalo = makeHalo(remote: entry.remote, scale: shape.contentsScale)
        let liveFill = CAShapeLayer()
        style(liveFill, remote: entry.remote, scale: shape.contentsScale)
        halos.addSublayer(liveHalo); fills.addSublayer(liveFill)
        let pieces = (halos: halos, fills: fills, liveHalo: liveHalo, liveFill: liveFill)
        entry.pieces = pieces
        return pieces
    }

    /// A stroke of one point is a dot; of none, nothing.
    private func dot(for stroke: Stroke) -> CGPath {
        let path = CGMutablePath()
        guard let first = stroke.points.first else { return path }
        let w = bounds.width, h = bounds.height
        let r = CGFloat(stroke.baseWidth) * 0.6
        path.addEllipse(in: CGRect(x: CGFloat(first.x) * w - r, y: CGFloat(first.y) * h - r, width: 2 * r, height: 2 * r))
        return path
    }

    /// Test only: the paths `id`'s ribbon is drawn with, the frozen pieces' oldest first and the live part's last (one
    /// path while it is all live), and their halos' paths in the same order.
    func ribbonForTesting(id: UInt32) -> (fills: [CGPath], halos: [CGPath])? {
        guard let entry = layers[id] else { return nil }
        guard let pieces = entry.pieces else {
            return (entry.shape.path.map { [$0] } ?? [], entry.shape.shadowPath.map { [$0] } ?? [])
        }
        return ((pieces.fills.sublayers ?? []).compactMap { ($0 as? CAShapeLayer)?.path },
                (pieces.halos.sublayers ?? []).compactMap(\.shadowPath))
    }

    /// Fades the stroke's layer out and then takes it off. The end of the fade goes by the layer, not the id alone: a
    /// fade can end after `attach` handed the canvas a new controller, whose ids start over, so by then the id can name
    /// the new share's stroke. `passive`: the fade four seconds after the last point, which eases in and out so the
    /// stroke fades away instead of popping off; otherwise (undo, clear) the entrance curve, quick and decided.
    func fade(id: UInt32, duration: Double, passive: Bool = false, curve given: CAMediaTimingFunction? = nil) {
        guard !fading.contains(id), let entry = layers[id] else { return }
        fading.insert(id)
        let curve = given ?? (passive ? CAMediaTimingFunction(name: .easeInEaseOut) : Theme.Motion.enter.timingFunction)
        animateOpacity(entry.shape, to: 0, duration: duration, curve: curve) { [weak self] in
            guard let self, layers[id] === entry else { return }
            entry.shape.removeFromSuperlayer(); layers[id] = nil; fading.remove(id)
        }
    }
    func remove(id: UInt32, duration: Double) { fade(id: id, duration: duration) }

    /// Takes the stroke off at once: this side's undo, a keyboard action.
    func removeNow(id: UInt32) {
        guard let entry = layers[id] else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        entry.shape.removeAllAnimations()
        entry.shape.removeFromSuperlayer()
        CATransaction.commit()
        layers[id] = nil; fading.remove(id)
    }

    /// Every stroke off at once: this side's clear.
    func removeAllNow() { layers.keys.forEach(removeNow(id:)) }

    /// Every stroke fades over 200 ms: the peer's clear.
    func fadeAll() {
        for id in layers.keys {
            fading.remove(id)
            fade(id: id, duration: Motion.clear.duration, curve: Motion.clear.timingFunction)
        }
    }

    /// The peer's undo (spec 11, M15): the stroke rewinds from its end to its start, a mask stroking its centre line
    /// (wide enough for its widest point, its halo and a margin, round caps) drawing back over 180 ms on the strong
    /// ease-in-out, the stroke fading over the last 80 ms. The mask sits on the stroke's layer, so it covers its frozen
    /// pieces and its halo too. Under Reduce Motion a 150 ms fade.
    func rewind(_ stroke: Stroke) {
        guard let entry = layers[stroke.id] else { return }
        guard !reduceMotion, stroke.points.count > 1 else {
            fade(id: stroke.id, duration: Motion.reducedRewind.duration, curve: Motion.reducedRewind.timingFunction)
            return
        }
        guard !fading.contains(stroke.id) else { return }
        fading.insert(stroke.id)
        let line = CGMutablePath()
        let centre = InkGeometry.smooth(stroke.points, segments: RibbonOutline.segments)
        for (i, v) in centre.enumerated() {
            let p = CGPoint(x: CGFloat(v.x) * bounds.width, y: CGFloat(v.y) * bounds.height)
            i == 0 ? line.move(to: p) : line.addLine(to: p)
        }
        let mask = CAShapeLayer()
        mask.frame = bounds
        mask.path = line
        mask.fillColor = nil
        mask.strokeColor = NSColor.black.cgColor
        mask.lineWidth = CGFloat(stroke.baseWidth) * 1.2 + 2 * Self.haloRadius + 3
        mask.lineCap = .round; mask.lineJoin = .round
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        entry.shape.mask = mask
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, layers[stroke.id] === entry else { return }
            entry.shape.removeFromSuperlayer(); layers[stroke.id] = nil; fading.remove(stroke.id)
        }
        let back = CABasicAnimation(keyPath: "strokeEnd")
        back.fromValue = 1; back.toValue = 0
        back.duration = Motion.rewind.duration
        back.timingFunction = Motion.rewind.timingFunction
        mask.strokeEnd = 0
        mask.add(back, forKey: "rewind")
        let out = CABasicAnimation(keyPath: "opacity")
        out.fromValue = 1; out.toValue = 0
        out.beginTime = entry.shape.convertTime(CACurrentMediaTime(), from: nil) + Motion.rewind.duration - Motion.rewindFade
        out.duration = Motion.rewindFade
        out.fillMode = .backwards
        entry.shape.opacity = 0
        entry.shape.add(out, forKey: "opacity")
        CATransaction.commit()
    }

    /// An opacity fade over `duration`, Reduce Motion or not: spec 11 takes away scale and the ring, and keeps fades as
    /// they are.
    private func animateOpacity(_ l: CALayer, to value: Float, duration: Double, curve: CAMediaTimingFunction,
                                completion: @escaping () -> Void) {
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = l.presentation()?.opacity ?? l.opacity; a.toValue = value
        a.duration = duration
        a.timingFunction = curve
        l.opacity = value
        l.add(a, forKey: "opacity")
        CATransaction.commit()
    }

    func hideRemoteCursor() { setCursorShown(false); lastRemoteCursor = nil }

    /// The peer's dot and its name pill in over 120 ms or out over 200 ms, explicitly: not the layers' implicit 250 ms.
    private func setCursorShown(_ shown: Bool) {
        let target: Float = shown ? 1 : 0
        guard cursorDot.opacity != target else { return }
        let curve = shown ? Motion.cursorIn : Motion.cursorOut
        for l in [cursorDot, cursorPill] {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = l.presentation()?.opacity ?? l.opacity
            a.toValue = target
            a.duration = curve.duration
            a.timingFunction = curve.timingFunction
            CATransaction.begin(); CATransaction.setDisableActions(true)
            l.opacity = target
            CATransaction.commit()
            l.add(a, forKey: "opacity")
        }
    }

    /// Test only: where the peer's dot is, and whether it shows.
    var remoteCursorForTesting: (position: CGPoint, visible: Bool) { (cursorDot.position, cursorDot.opacity > 0) }

    /// The peer's cursor: the gold dot, and 12 pt to its right the peer's name on a pill (6 by 3 pt of padding).
    func showRemoteCursor(_ c: Cursor, name: String) {
        lastRemoteCursor = (c, name)
        placeRemoteCursor(c, name: name)
        setCursorShown(c.visible)
    }

    /// The dot and the pill where `c` says, at the canvas's current size.
    private func placeRemoteCursor(_ c: Cursor, name: String) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        cursorDot.position = CGPoint(x: CGFloat(c.x) * bounds.width, y: CGFloat(c.y) * bounds.height)
        if cursorLabel.string as? String != name { cursorLabel.string = name }
        let text = (name as NSString).size(withAttributes: [.font: Self.cursorFont])
        let width = min(ceil(text.width), 200), height = ceil(text.height)
        cursorPill.frame = CGRect(x: cursorDot.position.x + 12, y: cursorDot.position.y - (height + 6) / 2,
                                  width: width + 12, height: height + 6)
        cursorLabel.frame = CGRect(x: 6, y: 3, width: width, height: height)
        CATransaction.commit()
    }
}

/// The outline of one stroke's ribbon, built as its points come: the smoothed centre line (`InkGeometry.smooth`, six
/// points per span) offset on each side by half the width at its point, the left edge forward and the right edge back.
/// Redrawn whole at every point, a ribbon cost more for each point than for the one before, so a peer growing a long
/// stroke a point at a time could hold the main actor longer and longer. A new point changes only the last two spans,
/// though: once a stretch of `pieceLength` points can no longer change, it is frozen as a finished piece, and each point
/// after it draws only the live part, between 3 and `pieceLength` + 2 points. A piece and the next meet on a shared
/// cross-section, and every outline point is the one the whole ribbon had there, computed the same way.
struct RibbonOutline {
    /// Points per frozen piece.
    static let pieceLength = 64
    /// Points of the centre line per span of the stroke, as `InkGeometry.smooth` makes them: point i of the stroke is
    /// centre point `segments * i`.
    static let segments = 6

    let baseWidth: Float
    let startedAt: Double
    /// The canvas size the outline is drawn at.
    let size: CGSize
    /// Each point's width so far, smoothed from the stroke's first point on, so a new point's needs only the one before.
    private var widths: [CGFloat] = []
    private var smoothed: Float
    /// The first point of the live part: the points before it are drawn by the frozen pieces.
    private(set) var liveStart = 0

    init(baseWidth: Float, startedAt: Double, size: CGSize) {
        self.baseWidth = baseWidth; self.startedAt = startedAt; self.size = size; smoothed = baseWidth
    }

    /// The stroke's points the outline has taken in.
    var pointCount: Int { widths.count }

    /// Takes in `pts` after the points it has (a stroke that only grew), and returns the paths of the pieces that can no
    /// longer change, oldest first. The outline at centre point j reads the centre points either side of it, so it is
    /// final once their spans are, and span i is final once point i + 2 exists: of n points, a piece can end at point
    /// n - 3.
    mutating func advance(to pts: [StrokePoint]) -> [CGPath] {
        for i in widths.count..<pts.count {
            let speed = i == 0 ? 0 : InkGeometry.speed(from: pts[i - 1], to: pts[i])
            let target = InkGeometry.width(base: baseWidth * pts[i].pressure, speedPerMs: speed)
            smoothed += (target - smoothed) * 0.3
            widths.append(CGFloat(smoothed))
        }
        var frozen: [CGPath] = []
        while liveStart + Self.pieceLength <= pts.count - 3 {
            let end = liveStart + Self.pieceLength
            frozen.append(path(pts, from: liveStart * Self.segments, through: end * Self.segments))
            liveStart = end
        }
        return frozen
    }

    /// The live part, from `liveStart` to the last of `pts` (the points `advance` took in last).
    func livePath(_ pts: [StrokePoint]) -> CGPath {
        path(pts, from: liveStart * Self.segments, through: (pts.count - 1) * Self.segments)
    }

    /// The closed outline through centre points `from` to `through`: the left edge forward, the right edge back. Only the
    /// spans those points and their neighbours lie on are smoothed.
    private func path(_ pts: [StrokePoint], from: Int, through: Int) -> CGPath {
        let segments = Self.segments
        let last = (pts.count - 1) * segments
        let lo = max(0, from - 1), hi = min(last, through + 1)
        // Centre point j > 0 lies on span (j - 1) / segments; centre point 0 is the stroke's first point.
        let firstSpan = lo == 0 ? 0 : (lo - 1) / segments
        var line = InkGeometry.smoothSpans(pts, firstSpan..<((hi - 1) / segments + 1), segments: segments)
        var base = firstSpan * segments + 1   // the centre point `line[0]` is
        if lo == 0 { line.insert(SIMD2(pts[0].x, pts[0].y), at: 0); base = 0 }
        let w = size.width, h = size.height
        func centre(_ j: Int) -> CGPoint { let v = line[j - base]; return CGPoint(x: CGFloat(v.x) * w, y: CGFloat(v.y) * h) }
        var left: [CGPoint] = [], right: [CGPoint] = []
        left.reserveCapacity(through - from + 1); right.reserveCapacity(through - from + 1)
        for i in from...through {
            let a = centre(max(0, i - 1)), b = centre(min(last, i + 1))
            var nx = -(b.y - a.y), ny = b.x - a.x
            let len = max(hypot(nx, ny), 0.0001); nx /= len; ny /= len
            let half = widths[min(widths.count - 1, i * (widths.count - 1) / max(1, last))] / 2
            let c = centre(i)
            left.append(CGPoint(x: c.x + nx * half, y: c.y + ny * half))
            right.append(CGPoint(x: c.x - nx * half, y: c.y - ny * half))
        }
        let path = CGMutablePath()
        path.move(to: left[0]); left.dropFirst().forEach { path.addLine(to: $0) }
        right.reversed().forEach { path.addLine(to: $0) }
        path.closeSubpath()
        return path
    }
}

public struct InkOverlay: NSViewRepresentable {
    public let controller: InkController
    public init(controller: InkController) { self.controller = controller }
    public func makeNSView(context: Context) -> InkCanvasView { InkCanvasView(controller: controller) }
    /// SwiftUI keeps the canvas when the model on screen changes: it draws for the controller it is handed now.
    public func updateNSView(_ view: InkCanvasView, context: Context) {
        view.attach(to: controller)
        view.reduceMotion = context.environment.reducesMotion
    }
}
