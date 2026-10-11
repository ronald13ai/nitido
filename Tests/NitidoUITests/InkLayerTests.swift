import XCTest
import AppKit
import SwiftUI
import QuartzCore
import NitidoCore
import NitidoCapture
@testable import NitidoUI

final class InkControllerTests: XCTestCase {
    private let a = StrokePoint(x: 0.1, y: 0.2, pressure: 1, tMs: 0)
    private let b = StrokePoint(x: 0.3, y: 0.4, pressure: 1, tMs: 16)

    @MainActor
    private func drawLocal(_ ink: InkController) -> UInt32 {
        let id = ink.beginLocal(a)
        ink.appendLocal(id, [b])
        ink.endLocal(id)
        return id
    }

    /// A local stroke goes out as begin, append and end, in gold at width 4, under an even (share side) id.
    @MainActor
    func testLocalStrokeSendsBeginAppendEndUnderAShareId() {
        let ink = InkController(role: .share)
        var sent: [Message] = []
        ink.onOutgoing = { sent.append($0) }
        let id = drawLocal(ink)
        XCTAssertEqual(id % 2, 0, "the share side allocates even ids")
        XCTAssertEqual(sent, [
            .stroke(StrokeMessage(strokeId: id, phase: .begin, color: .gold, baseWidth: 4, points: [a])),
            .stroke(StrokeMessage(strokeId: id, phase: .append, color: .gold, baseWidth: 4, points: [b])),
            .stroke(StrokeMessage(strokeId: id, phase: .end, color: .gold, baseWidth: 4, points: [])),
        ])
        XCTAssertEqual(ink.document.strokes.map(\.points), [[a, b]])
        XCTAssertEqual(ink.document.strokes.first?.isRemote, false)
        XCTAssertNotNil(ink.document.strokes.first?.endedAt)
    }

    /// The view side allocates odd ids, so the two peers never collide.
    @MainActor
    func testViewSideAllocatesOddIds() {
        let ink = InkController(role: .view)
        XCTAssertEqual(drawLocal(ink) % 2, 1)
    }

    /// ⌘Z takes back the newest local stroke only, never the peer's, and tells the peer which one.
    @MainActor
    func testUndoLocalRemovesTheNewestLocalStrokeAndTellsThePeer() {
        let ink = InkController(role: .share)
        let first = drawLocal(ink)
        let second = drawLocal(ink)
        ink.applyRemote(StrokeMessage(strokeId: 3, phase: .begin, color: .cream, baseWidth: 4, points: [a]))
        var sent: [Message] = []
        ink.onOutgoing = { sent.append($0) }
        ink.undoLocal()
        XCTAssertEqual(sent, [.undo(strokeId: second)])
        XCTAssertEqual(ink.document.strokes.map(\.id), [first, 3])
    }

    /// With only the peer's strokes on the picture, ⌘Z does nothing and sends nothing.
    @MainActor
    func testUndoLocalWithoutALocalStrokeSendsNothing() {
        let ink = InkController(role: .share)
        ink.applyRemote(StrokeMessage(strokeId: 3, phase: .begin, color: .cream, baseWidth: 4, points: [a]))
        var sent: [Message] = []
        ink.onOutgoing = { sent.append($0) }
        ink.undoLocal()
        XCTAssertEqual(sent, [])
        XCTAssertEqual(ink.document.strokes.map(\.id), [3])
    }

    /// ⌘⌫ clears every stroke, both sides', and tells the peer.
    @MainActor
    func testClearLocalEmptiesTheDocumentAndTellsThePeer() {
        let ink = InkController(role: .share)
        _ = drawLocal(ink)
        ink.applyRemote(StrokeMessage(strokeId: 3, phase: .begin, color: .cream, baseWidth: 4, points: [a]))
        var sent: [Message] = []
        ink.onOutgoing = { sent.append($0) }
        ink.clearLocal()
        XCTAssertEqual(sent, [.clear])
        XCTAssertTrue(ink.document.strokes.isEmpty)
    }

    /// The peer's ids carry the peer's parity (the sharer's even, the viewer's odd): one with this side's parity would
    /// erase or take over this side's own strokes, and is ignored, as an undo of a stroke that is not the peer's is.
    @MainActor
    func testThePeersIdsMustHaveThePeersParity() {
        let ink = InkController(role: .share)
        let own = drawLocal(ink)
        ink.applyRemote(StrokeMessage(strokeId: own, phase: .begin, color: .cream, baseWidth: 4, points: [b]))
        ink.applyRemote(StrokeMessage(strokeId: own, phase: .append, color: .cream, baseWidth: 4, points: [b]))
        ink.undoRemote(id: own)
        XCTAssertEqual(ink.document.strokes.map(\.id), [own])
        XCTAssertEqual(ink.document.strokes.first?.points, [a, b], "this side's stroke is untouched")
        XCTAssertEqual(ink.document.strokes.first?.isRemote, false)
        let viewerInk = InkController(role: .view)
        viewerInk.applyRemote(StrokeMessage(strokeId: 3, phase: .begin, color: .cream, baseWidth: 4, points: [a]))
        XCTAssertTrue(viewerInk.document.strokes.isEmpty, "an odd id is the viewer's own")
        viewerInk.applyRemote(StrokeMessage(strokeId: 4, phase: .begin, color: .cream, baseWidth: 4, points: [a]))
        XCTAssertEqual(viewerInk.document.strokes.map(\.id), [4])
    }

    /// A peer cannot grow this side's ink without bound: at most 64 of its strokes are being drawn at once, at most
    /// 10,000 points each, and its values are kept inside the picture (a point that is not a number is dropped, the
    /// width kept within 1 to 32 points).
    @MainActor
    func testThePeersInkIsBounded() {
        let ink = InkController(role: .share)
        for i in 0..<70 {
            ink.applyRemote(StrokeMessage(strokeId: UInt32(2 * i + 1), phase: .begin, color: .cream, baseWidth: 4, points: [a]))
        }
        XCTAssertEqual(ink.document.strokes.count, InkController.maxRemoteStrokesInFlight)
        ink.applyRemote(StrokeMessage(strokeId: 1, phase: .end, color: .cream, baseWidth: 4, points: []))
        ink.applyRemote(StrokeMessage(strokeId: 201, phase: .begin, color: .cream, baseWidth: 4, points: [a]))
        XCTAssertTrue(ink.document.strokes.contains { $0.id == 201 }, "an ended stroke frees its place")

        let many = Array(repeating: b, count: 6_000)
        ink.applyRemote(StrokeMessage(strokeId: 3, phase: .append, color: .cream, baseWidth: 4, points: many))
        ink.applyRemote(StrokeMessage(strokeId: 3, phase: .append, color: .cream, baseWidth: 4, points: many))
        XCTAssertEqual(ink.document.strokes.first { $0.id == 3 }?.points.count, InkController.maxPointsPerStroke)

        let odd = [StrokePoint(x: .nan, y: 0.5, pressure: 1, tMs: 1), StrokePoint(x: 2, y: -1, pressure: 9, tMs: 2),
                   StrokePoint(x: 0.5, y: .infinity, pressure: 1, tMs: 3), StrokePoint(x: 0.5, y: 0.5, pressure: .nan, tMs: 4)]
        let fresh = InkController(role: .share)
        fresh.applyRemote(StrokeMessage(strokeId: 301, phase: .begin, color: .cream, baseWidth: .nan, points: odd))
        let stroke = fresh.document.strokes.first { $0.id == 301 }
        XCTAssertEqual(stroke?.points, [StrokePoint(x: 1, y: 0, pressure: 1, tMs: 2)])
        XCTAssertEqual(stroke?.baseWidth, 4)
        fresh.applyRemote(StrokeMessage(strokeId: 303, phase: .begin, color: .cream, baseWidth: 1e30, points: [a]))
        XCTAssertEqual(fresh.document.strokes.first { $0.id == 303 }?.baseWidth, 32)
    }

    /// What the peer sends is applied and never sent back.
    @MainActor
    func testRemoteChangesAreAppliedAndNeverEchoed() {
        let ink = InkController(role: .share)
        var sent: [Message] = []
        ink.onOutgoing = { sent.append($0) }
        ink.applyRemote(StrokeMessage(strokeId: 3, phase: .begin, color: .cream, baseWidth: 4, points: [a]))
        ink.applyRemote(StrokeMessage(strokeId: 3, phase: .append, color: .cream, baseWidth: 4, points: [b]))
        XCTAssertEqual(ink.document.strokes.map(\.points), [[a, b]])
        XCTAssertEqual(ink.document.strokes.first?.isRemote, true)
        ink.applyRemote(StrokeMessage(strokeId: 5, phase: .begin, color: .cream, baseWidth: 4, points: [a]))
        ink.undoRemote(id: 3)
        XCTAssertEqual(ink.document.strokes.map(\.id), [5])
        ink.remoteCursor(Cursor(x: 0.5, y: 0.5, visible: true), name: "Peer")
        ink.clearRemote()
        XCTAssertTrue(ink.document.strokes.isEmpty)
        XCTAssertEqual(sent, [], "remote changes are never echoed to the peer")
    }
}

/// The time stamp on each point is the milliseconds since the stroke began, as a `UInt32`. It must never trap:
/// before the first stroke the start is 0, so a hover would otherwise stamp the machine's awake uptime, which
/// passes `UInt32.max` milliseconds after about 49.7 days.
final class InkTimestampTests: XCTestCase {
    func testElapsedMillisecondsSinceTheStrokeBegan() {
        XCTAssertEqual(InkCanvasView.elapsedMs(since: 10, now: 10.016), 16)
        XCTAssertEqual(InkCanvasView.elapsedMs(since: 10, now: 10), 0)
    }

    func testAClockBeforeTheStartGivesZero() {
        XCTAssertEqual(InkCanvasView.elapsedMs(since: 10, now: 9), 0)
    }

    func testAnUptimeThatStillFitsIsKept() {
        // About 29.8 days of awake time, as seen on a real Mac: 2,578,972 s.
        XCTAssertEqual(InkCanvasView.elapsedMs(since: 0, now: 2_578_972), 2_578_972_000)
    }

    func testAnUptimePastTheRangeIsClampedInsteadOfTrapping() {
        let fiftyDays = 50.0 * 24 * 60 * 60
        XCTAssertEqual(InkCanvasView.elapsedMs(since: 0, now: fiftyDays), UInt32.max)
        XCTAssertEqual(InkCanvasView.elapsedMs(since: 0, now: Double(UInt32.max) / 1000 + 1), UInt32.max)
        XCTAssertEqual(InkCanvasView.elapsedMs(since: 0, now: 1e12), UInt32.max)
        XCTAssertEqual(InkCanvasView.elapsedMs(since: 0, now: .infinity), UInt32.max)
    }

    func testANonNumberGivesZero() {
        XCTAssertEqual(InkCanvasView.elapsedMs(since: 0, now: .nan), 0)
    }
}

/// A capture source that never sends anything: the share stays idle, which is enough to lay out the picture area.
@MainActor
private final class IdleSource: CaptureSource {
    let frames = AsyncStream<CapturedFrame> { _ in }
    let events = AsyncStream<CaptureEvent> { _ in }
    func presentPicker(excludingWindowIDs: [CGWindowID]) {}
    func stop() async {}
}

final class InkOverlayTests: XCTestCase {
    @MainActor
    private func settle(_ view: NSView) async {
        for _ in 0..<6 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
        view.layoutSubtreeIfNeeded()
    }

    /// The Share view in an out of sight window, as `DividerHandleTests` does.
    @MainActor
    private func hostShare(_ model: ShareModel) async -> (NSHostingView<ShareView>, NSWindow) {
        _ = NSApplication.shared
        let picture = model.fittedPointSize
        let host = NSHostingView(rootView: ShareView(model: model))
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: picture.width, height: picture.height + 80),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        await settle(host)
        return (host, window)
    }

    /// The view AppKit sends a click at `point` (picture top left coordinates) to.
    @MainActor
    private func hit(_ point: CGPoint, in host: NSView) -> NSView? {
        guard let container = host.superview else { return host.hitTest(point) }
        return container.hitTest(host.convert(point, to: container))
    }

    /// The ink sits above the video and takes clicks on the picture; with the codec loop on the divider handle
    /// above it takes them instead.
    @MainActor
    func testTheInkTakesClicksOnThePictureUnlessTheLoopIsOn() async throws {
        let model = ShareModel(makeSource: { IdleSource() }, screenRecordingGranted: { true })
        let (host, window) = await hostShare(model)
        defer { window.orderOut(nil); window.contentView = nil }
        let canvas = try XCTUnwrap(model.ink.canvas, "the Share view hosts the ink overlay")
        let picture = model.fittedPointSize
        XCTAssertEqual(canvas.bounds.size, picture, "the ink covers the whole picture")
        let center = CGPoint(x: picture.width / 2, y: picture.height / 2)
        XCTAssertTrue(hit(center, in: host) === canvas, "a click on the picture reaches the ink")
        // The bottom corners are clear of the panels: the ink reaches the picture's edges, not just its middle.
        XCTAssertTrue(hit(CGPoint(x: 2, y: picture.height - 2), in: host) === canvas, "the bottom left corner reaches the ink")
        XCTAssertTrue(hit(CGPoint(x: picture.width - 2, y: picture.height - 2), in: host) === canvas, "the bottom right corner reaches the ink")

        model.loopback = true
        await settle(host)
        XCTAssertFalse(hit(center, in: host) === canvas, "with the loop on the divider handle takes the drag")
    }

    /// A drag on the picture draws one stroke in normalized picture coordinates (top left origin), sends the pointer
    /// as a cursor, and leaves a ribbon layer; ⌘Z fades that layer out.
    @MainActor
    func testADragDrawsAStrokeInPictureCoordinates() async throws {
        let model = ShareModel(makeSource: { IdleSource() }, screenRecordingGranted: { true })
        let (host, window) = await hostShare(model)
        defer { window.orderOut(nil); window.contentView = nil }
        let canvas = try XCTUnwrap(model.ink.canvas)
        let picture = model.fittedPointSize
        var sent: [Message] = []
        model.ink.onOutgoing = { sent.append($0) }

        func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) throws -> NSEvent {
            let location = host.convert(CGPoint(x: picture.width * x, y: picture.height * y), to: nil)
            return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                    context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        }
        canvas.mouseDown(with: try event(.leftMouseDown, 0.25, 0.25))
        canvas.mouseDragged(with: try event(.leftMouseDragged, 0.5, 0.75))
        canvas.mouseUp(with: try event(.leftMouseUp, 0.5, 0.75))

        let strokes = sent.compactMap { if case .stroke(let m) = $0 { m } else { nil } }
        XCTAssertEqual(strokes.map(\.phase), [.begin, .append, .end])
        let begin = try XCTUnwrap(strokes.first?.points.first)
        XCTAssertEqual(begin.x, 0.25, accuracy: 0.002)
        XCTAssertEqual(begin.y, 0.25, accuracy: 0.002)
        let moved = try XCTUnwrap(strokes.dropFirst().first?.points.first)
        XCTAssertEqual(moved.x, 0.5, accuracy: 0.002)
        XCTAssertEqual(moved.y, 0.75, accuracy: 0.002)
        XCTAssertTrue(sent.contains { if case .cursor(let c) = $0 { c.visible && abs(c.x - 0.5) < 0.002 && abs(c.y - 0.75) < 0.002 } else { false } },
                      "the pointer goes out as a cursor while drawing")
        XCTAssertEqual(model.ink.document.strokes.count, 1)

        let ribbons = (canvas.layer?.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
        XCTAssertEqual(ribbons.count, 1, "one layer per stroke")
        let box = try XCTUnwrap(ribbons.first?.path?.boundingBoxOfPath)
        XCTAssertTrue(box.insetBy(dx: -1, dy: -1).contains(CGPoint(x: picture.width * 0.25, y: picture.height * 0.25)))
        XCTAssertTrue(box.insetBy(dx: -1, dy: -1).contains(CGPoint(x: picture.width * 0.5, y: picture.height * 0.75)))

        model.ink.undoLocal()
        XCTAssertTrue(model.ink.document.strokes.isEmpty)
        XCTAssertEqual(ribbons.first?.opacity, 0, "⌘Z fades the stroke out")
    }
}

/// The crash of the evening two-Mac test (2026-10-09 21:52:50): a share stopped and a new one started, SwiftUI kept the
/// ink canvas and handed it the new share's controller, and the canvas's tick reached the old controller, gone by then,
/// through an unowned reference (`swift_abortRetainUnowned` in `InkCanvasView.init(controller:)`'s timer). The canvas
/// holds its controller weakly, follows the one it is handed, ticks only while it is in a window, and stops when it
/// leaves it or goes.
final class InkCanvasLifetimeTests: XCTestCase {
    @MainActor
    private func offscreenWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 320, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    /// The ribbon layers on `canvas`, one per stroke it draws.
    @MainActor
    private func ribbons(on canvas: InkCanvasView) -> [CAShapeLayer] {
        (canvas.layer?.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
    }

    private let point = StrokePoint(x: 0.25, y: 0.25, pressure: 1, tMs: 0)

    /// A canvas whose controller has gone ticks without crashing, and does nothing.
    @MainActor
    func testACanvasWhoseControllerIsGoneTicksWithoutCrashing() throws {
        let window = offscreenWindow()
        defer { window.contentView = nil }
        var controller: InkController? = InkController(role: .share)
        let canvas = InkCanvasView(controller: try XCTUnwrap(controller))
        _ = try XCTUnwrap(controller).beginLocal(point)
        window.contentView?.addSubview(canvas)
        let tick = try XCTUnwrap(canvas.tickTimer, "a canvas in a window with a stroke ticks")
        weak let gone = controller
        controller = nil
        XCTAssertNil(gone, "the controller went with its share")
        tick.fire()
        XCTAssertNil(canvas.controller)
    }

    /// The canvas ticks only while it is in a window, and a canvas let go while its tick is scheduled goes (the tick
    /// holds it weakly) and invalidates the tick as it goes (the test seam starts the tick without a window).
    @MainActor
    func testACanvasOutOfItsWindowOrGoneStopsTicking() throws {
        let window = offscreenWindow()
        defer { window.contentView = nil }
        let controller = InkController(role: .share)
        let canvas = InkCanvasView(controller: controller)
        _ = controller.beginLocal(point)
        XCTAssertNil(canvas.tickTimer, "out of a window there is nothing to fade")
        window.contentView?.addSubview(canvas)
        let first = try XCTUnwrap(canvas.tickTimer)
        let before = controller.ticks
        first.fire()
        XCTAssertEqual(controller.ticks, before + 1, "the tick reaches the controller")
        canvas.removeFromSuperview()
        XCTAssertFalse(first.isValid, "out of its window the canvas stops ticking")
        XCTAssertNil(canvas.tickTimer)

        var scheduled: Timer?
        weak var gone: InkCanvasView?
        autoreleasepool {
            let other = InkCanvasView(controller: controller)
            other.startTicking()
            scheduled = other.tickTimer
            gone = other
        }
        XCTAssertNil(gone, "the scheduled tick does not keep the canvas alive")
        XCTAssertEqual(scheduled?.isValid, false, "its tick went with it")
    }

    /// SwiftUI keeps the canvas when the share on screen is replaced by a new one and hands it the new controller: the
    /// canvas draws for that one from then on, the old one no longer points at it, and the old one going away leaves
    /// the tick working.
    @MainActor
    func testACanvasSwiftUIKeepsFollowsItsNewController() async throws {
        let window = offscreenWindow()
        defer { window.contentView = nil }
        var first: InkController? = InkController(role: .share)
        let second = InkController(role: .share)
        let host = NSHostingView(rootView: InkOverlay(controller: try XCTUnwrap(first)))
        window.contentView = host
        for _ in 0..<6 { await Task.yield(); try await Task.sleep(for: .milliseconds(10)) }
        host.layoutSubtreeIfNeeded()
        let canvas = try XCTUnwrap(first?.canvas, "the overlay made its canvas")

        host.rootView = InkOverlay(controller: second)
        for _ in 0..<6 { await Task.yield(); try await Task.sleep(for: .milliseconds(10)) }
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(second.canvas === canvas, "SwiftUI kept the canvas")
        XCTAssertTrue(canvas.controller === second, "the canvas follows the controller it is handed")
        XCTAssertNil(first?.canvas, "the old controller no longer draws into it")

        weak let gone = first
        first = nil
        XCTAssertNil(gone)
        _ = second.beginLocal(point)
        let before = second.ticks
        try XCTUnwrap(canvas.tickTimer, "the new controller's stroke starts the tick").fire()
        XCTAssertEqual(second.ticks, before + 1)
    }

    /// Spec 11, "nothing animates on every frame except the picture and the sparkline": the 30 Hz tick runs only while
    /// there are strokes to fade, from the first stroke until the last one is gone.
    @MainActor
    func testTheCanvasTicksOnlyWhileItHasStrokes() throws {
        let window = offscreenWindow()
        defer { window.contentView = nil }
        let controller = InkController(role: .share)
        let canvas = InkCanvasView(controller: controller)
        canvas.frame = NSRect(x: 0, y: 0, width: 320, height: 200)
        window.contentView?.addSubview(canvas)
        XCTAssertNil(canvas.tickTimer, "in a window, with no ink, nothing ticks")
        let id = controller.beginLocal(point)
        let tick = try XCTUnwrap(canvas.tickTimer, "the first stroke starts the tick")
        controller.endLocal(id)
        tick.fire()
        XCTAssertNotNil(canvas.tickTimer, "a stroke still to fade keeps it")
        controller.undoLocal()
        tick.fire()
        XCTAssertNil(canvas.tickTimer, "the last stroke gone, the tick stops")
        XCTAssertFalse(tick.isValid)
        _ = controller.beginLocal(point)
        XCTAssertNotNil(canvas.tickTimer, "the next stroke starts it again")
    }

    /// The canvas holds its controller weakly, so the old share and its controller can be gone before SwiftUI hands
    /// the canvas the new one. Their strokes come off all the same: only the old controller's tick would have faded
    /// them, and the new share starts on a clean canvas.
    @MainActor
    func testTheStrokesOfAControllerGoneBeforeTheSwitchComeOff() throws {
        var first: InkController? = InkController(role: .share)
        let second = InkController(role: .share)
        let canvas = InkCanvasView(controller: try XCTUnwrap(first))
        canvas.frame = NSRect(x: 0, y: 0, width: 320, height: 200)
        _ = try XCTUnwrap(first).beginLocal(point)
        XCTAssertEqual(ribbons(on: canvas).count, 1, "the first share's stroke is on the canvas")
        weak let gone = first
        first = nil
        XCTAssertNil(gone, "the first share went with its controller")
        XCTAssertNil(canvas.controller)

        canvas.attach(to: second)
        XCTAssertEqual(ribbons(on: canvas).count, 0, "the gone share's stroke is taken off")
        XCTAssertTrue(canvas.controller === second)
        XCTAssertTrue(second.canvas === canvas)
    }

    /// A fade started for the old controller can end after the switch, and every share's ids start over: the new
    /// share's first stroke has the id the old share's had. The fade takes off its own layer only, never the new
    /// stroke's.
    @MainActor
    func testAFadeFromBeforeTheSwitchLeavesTheNewSharesStrokeUnderTheSameId() async throws {
        let window = offscreenWindow()
        defer { window.contentView = nil }
        let first = InkController(role: .share)
        let second = InkController(role: .share)
        let canvas = InkCanvasView(controller: first)
        canvas.frame = NSRect(x: 0, y: 0, width: 320, height: 200)
        window.contentView?.addSubview(canvas)
        let old = first.beginLocal(point)
        canvas.fade(id: old, duration: 0.05)

        canvas.attach(to: second)
        let new = second.beginLocal(point)
        XCTAssertEqual(new, old, "a new share's ids start over")
        let stroke = try XCTUnwrap(ribbons(on: canvas).first, "the new share's stroke is on the canvas")
        try await Task.sleep(for: .milliseconds(400))     // the old fade has ended
        XCTAssertEqual(ribbons(on: canvas).count, 1, "the old fade left the new share's stroke")
        XCTAssertTrue(ribbons(on: canvas).first === stroke)
        XCTAssertEqual(stroke.opacity, 1)
    }

    /// A peer's cursor with a coordinate that is not a number (one 14-byte message from a Mac holding the code) made Core
    /// Animation raise `CALayerInvalidGeometry` and abort the app. It is dropped, and the dot stays where it was; an
    /// infinite or out-of-range one is dropped or kept inside the picture. Through the viewer's own handler too.
    @MainActor
    func testAPeersCursorThatIsNotANumberLeavesTheDotWhereItWas() throws {
        let window = offscreenWindow()
        defer { window.contentView = nil }
        let viewer = ViewModel(startingDiscovery: false)
        let canvas = InkCanvasView(controller: viewer.ink)
        canvas.frame = NSRect(x: 0, y: 0, width: 320, height: 200)
        window.contentView?.addSubview(canvas)
        viewer.handleIncoming(.cursor(Cursor(x: 0.5, y: 0.5, visible: true)))
        XCTAssertEqual(canvas.remoteCursorForTesting.position, CGPoint(x: 160, y: 100))
        for bad in [Cursor(x: .nan, y: .nan, visible: true), Cursor(x: .infinity, y: 0.5, visible: true),
                    Cursor(x: 0.5, y: -.infinity, visible: true), Cursor(x: .nan, y: 0.5, visible: false)] {
            viewer.handleIncoming(.cursor(bad))
            XCTAssertEqual(canvas.remoteCursorForTesting.position, CGPoint(x: 160, y: 100), "\(bad)")
            XCTAssertTrue(canvas.remoteCursorForTesting.visible)
        }
        viewer.handleIncoming(.cursor(Cursor(x: 7, y: -3, visible: true)))
        XCTAssertEqual(canvas.remoteCursorForTesting.position, CGPoint(x: 320, y: 0), "kept inside the picture")
    }

    /// The canvas changes size (the window moved to a display of another scale, the capture resized): the strokes and
    /// the peer's cursor, kept in picture units, are laid out again at the new size, rather than staying at the old place
    /// and scale until they fade.
    @MainActor
    func testStrokesAndThePeersCursorFollowANewSize() throws {
        let window = offscreenWindow()
        defer { window.contentView = nil }
        let ink = InkController(role: .share)
        let canvas = InkCanvasView(controller: ink)
        canvas.frame = NSRect(x: 0, y: 0, width: 320, height: 200)
        window.contentView?.addSubview(canvas)
        ink.applyRemote(StrokeMessage(strokeId: 3, phase: .begin, color: .cream, baseWidth: 4, points: [point]))
        ink.remoteCursor(Cursor(x: 0.5, y: 0.5, visible: true), name: "Peer")
        let stroke = try XCTUnwrap(ribbons(on: canvas).first)
        XCTAssertEqual(stroke.path?.boundingBox.midX ?? 0, 80, accuracy: 0.5)
        canvas.setFrameSize(NSSize(width: 640, height: 400))
        XCTAssertEqual(stroke.path?.boundingBox.midX ?? 0, 160, accuracy: 0.5, "a quarter of the way across, at the new size")
        XCTAssertEqual(stroke.path?.boundingBox.midY ?? 0, 100, accuracy: 0.5)
        XCTAssertEqual(stroke.shadowPath, stroke.path, "the halo follows")
        XCTAssertEqual(canvas.remoteCursorForTesting.position, CGPoint(x: 320, y: 200), "the peer's dot too")
    }

    /// ⌘Tab away (or a click in another app) while the pointer is over the picture: AppKit sends no `mouseExited`, so the
    /// canvas hides this side's dot on the peer when its window stops being key or goes to the Dock.
    @MainActor
    func testThePointerIsHiddenFromThePeerWhenTheWindowStopsBeingKey() throws {
        let window = offscreenWindow()
        defer { window.contentView = nil }
        let ink = InkController(role: .view)
        var sent: [Message] = []
        ink.onOutgoing = { sent.append($0) }
        let canvas = InkCanvasView(controller: ink)
        canvas.frame = NSRect(x: 0, y: 0, width: 320, height: 200)
        window.contentView?.addSubview(canvas)
        let move = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: 160, y: 100), modifierFlags: [],
                                                    timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                    clickCount: 0, pressure: 0))
        canvas.mouseMoved(with: move)
        XCTAssertEqual(sent.last, .cursor(Cursor(x: 0.5, y: 0.5, visible: true)))
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertEqual(sent.last, .cursor(Cursor(x: 0, y: 0, visible: false)), "hidden on the peer")
        let count = sent.count
        NotificationCenter.default.post(name: NSWindow.didMiniaturizeNotification, object: window)
        XCTAssertEqual(sent.count, count, "once: it is hidden already")
    }

    /// The peer's name sits on a solid pill with a hairline, so a document's text does not show through it.
    @MainActor
    func testThePeersNameSitsOnASolidPill() {
        let canvas = InkCanvasView(controller: InkController(role: .share))
        let pill = canvas.layer?.sublayers?.first { $0.cornerRadius == 6 }
        XCTAssertEqual(pill?.backgroundColor?.alpha, 1)
        XCTAssertEqual(pill?.borderWidth, 1)
    }

    /// The canvas draws with the theme's palette (spec 11), defined once for SwiftUI and the layers: this side's strokes
    /// in gold, the peer's in cream. A fade lasts what it is asked for: Reduce Motion takes away scale and the ring, never
    /// the fades.
    @MainActor
    func testTheCanvasDrawsInTheThemesGoldAndCreamAndFadesForTheWholeDuration() throws {
        let window = offscreenWindow()
        defer { window.contentView = nil }
        let ink = InkController(role: .share)
        let canvas = InkCanvasView(controller: ink)
        canvas.frame = NSRect(x: 0, y: 0, width: 320, height: 200)
        window.contentView?.addSubview(canvas)
        let own = ink.beginLocal(point)
        ink.applyRemote(StrokeMessage(strokeId: 3, phase: .begin, color: .cream, baseWidth: 4, points: [point]))
        let layers = ribbons(on: canvas)
        XCTAssertEqual(layers.count, 2)
        XCTAssertEqual(layers.first?.fillColor, NSColor(srgbRed: 0xc9 / 255, green: 0xa8 / 255, blue: 0x6a / 255, alpha: 1).cgColor, "gold")
        XCTAssertEqual(layers.last?.fillColor, NSColor(srgbRed: 0xf3 / 255, green: 0xe3 / 255, blue: 0xba / 255, alpha: 1).cgColor, "cream")
        // A soft dark halo, so the cream and the gold read on a white document.
        XCTAssertEqual(layers.last?.shadowOpacity, 0.35)
        XCTAssertEqual(layers.last?.shadowRadius, 1.5)
        XCTAssertNotNil(layers.last?.shadowPath, "the halo follows the ribbon's path")
        canvas.fade(id: own, duration: 0.6)
        XCTAssertEqual(layers.first?.animation(forKey: "opacity")?.duration, 0.6)
    }
}

/// A long stroke is drawn in pieces (`RibbonOutline`): each new point costs the canvas the same at its end as at its
/// start, so a peer that grows one stroke a point at a time cannot make every point cost more on the main actor than the
/// one before (spec 6), and the pieces draw the ribbon the whole stroke drew.
final class InkRibbonPiecesTests: XCTestCase {
    /// A point of a long, winding stroke, about 8 ms after the one before, as a trackpad gives them.
    private func point(_ i: Int) -> StrokePoint {
        let t = Float(i)
        return StrokePoint(x: 0.5 + 0.4 * cos(t / 50), y: 0.5 + 0.3 * sin(t / 70), pressure: 0.6 + 0.4 * sin(t / 9), tMs: UInt32(i * 8))
    }

    /// 2000 points appended one by one to one of the peer's strokes: the last hundred appends together take no more
    /// than three times the first hundred. Redrawn whole at every point, the ribbon made them about forty times slower.
    @MainActor
    func testEachAppendedPointCostsBoundedTime() {
        let ink = InkController(role: .share)
        let canvas = InkCanvasView(controller: ink)
        canvas.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        ink.applyRemote(StrokeMessage(strokeId: 3, phase: .begin, color: .cream, baseWidth: 4, points: [point(0)]))
        let clock = ContinuousClock()
        var costs: [Duration] = []
        costs.reserveCapacity(2000)
        for i in 1...2000 {
            let m = StrokeMessage(strokeId: 3, phase: .append, color: .cream, baseWidth: 4, points: [point(i)])
            let start = clock.now
            ink.applyRemote(m)
            costs.append(clock.now - start)
        }
        XCTAssertEqual(ink.document.strokes.first?.points.count, 2001)
        let first = costs.prefix(100).reduce(Duration.zero, +), last = costs.suffix(100).reduce(Duration.zero, +)
        XCTAssertLessThanOrEqual(last, first * 6, "the last 100 appends took \(last), the first 100 \(first); the bound is loose so one scheduler preemption cannot fail it, while the old quadratic ribbon took about 37x")
    }

    /// Drawn in pieces as it grows, a long stroke has the very outline the whole ribbon had: every point of both edges
    /// the same, at every length (a piece just frozen, just before and after it, points coming several at a time), and
    /// again after a resize; the pieces meet on a shared cross-section, and each piece's halo follows it.
    @MainActor
    func testAStrokeDrawnInPiecesHasTheWholeRibbonsOutline() throws {
        let ink = InkController(role: .share)
        let canvas = InkCanvasView(controller: ink)
        canvas.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        var sent = [point(0)]
        ink.applyRemote(StrokeMessage(strokeId: 3, phase: .begin, color: .cream, baseWidth: 5, points: sent))
        func check(_ when: String) throws {
            let drawn = try XCTUnwrap(canvas.ribbonForTesting(id: 3))
            XCTAssertEqual(drawn.halos, drawn.fills, "each halo follows its piece \(when)")
            var left: [CGPoint] = [], right: [CGPoint] = []
            for (n, fill) in drawn.fills.enumerated() {
                let piece = edges(of: fill)
                guard n > 0 else { (left, right) = piece; continue }
                XCTAssertEqual(piece.left.first, left.last, "pieces meet \(when)")
                XCTAssertEqual(piece.right.first, right.last, "pieces meet \(when)")
                left += piece.left.dropFirst(); right += piece.right.dropFirst()
            }
            let whole = wholeOutline(sent, baseWidth: 5, size: canvas.bounds.size)
            XCTAssertTrue(left == whole.left && right == whole.right, "the whole ribbon's outline \(when)")
        }
        for target in [2, 3, 7, 66, 67, 68, 69, 70, 131, 132, 133, 200, 777] {
            while sent.count < target {
                // One point at a time, and from 200 on five at a time where they fit.
                let more = sent.count >= 200 ? min(5, target - sent.count) : 1
                let points = (sent.count..<(sent.count + more)).map(point)
                ink.applyRemote(StrokeMessage(strokeId: 3, phase: .append, color: .cream, baseWidth: 5, points: points))
                sent += points
            }
            try check("at \(target) points")
        }
        XCTAssertEqual(canvas.ribbonForTesting(id: 3)?.fills.count, 13, "777 points: twelve pieces of 64 and the live part")
        canvas.setFrameSize(NSSize(width: 640, height: 400))
        try check("after a resize")
    }

    /// Drawn in pieces, a long stroke looks like the whole ribbon. Rendered offscreen on white at 1x and 2x, against the
    /// whole ribbon's polygon halo under its fill and edge line (what Core Animation draws for one layer with that
    /// `shadowPath`; its offscreen renderer shades what a layer draws instead, so the reference is built that way), no
    /// channel is more than 10 % off and under 1 % of the ribbon's channels are off at all: a few pixels of antialiasing
    /// where two pieces meet. Every halo lies under every fill; a piece's halo over the piece before it would darken a
    /// band across the ribbon at each joint.
    @MainActor
    func testAStrokeDrawnInPiecesLooksLikeTheWholeRibbon() throws {
        let ink = InkController(role: .share)
        let canvas = InkCanvasView(controller: ink)
        canvas.frame = NSRect(x: 0, y: 0, width: 400, height: 250)
        let pts = (0..<300).map(point)
        ink.applyRemote(StrokeMessage(strokeId: 3, phase: .begin, color: .cream, baseWidth: 5, points: [pts[0]]))
        for p in pts.dropFirst() { ink.applyRemote(StrokeMessage(strokeId: 3, phase: .append, color: .cream, baseWidth: 5, points: [p])) }
        XCTAssertEqual(canvas.ribbonForTesting(id: 3)?.fills.count, 5, "four pieces and the live part")
        let stroke = try XCTUnwrap((canvas.layer?.sublayers ?? []).compactMap { $0 as? CAShapeLayer }.first)

        let outline = wholeOutline(pts, baseWidth: 5, size: canvas.bounds.size)
        let whole = CGMutablePath()
        whole.move(to: outline.left[0]); outline.left.dropFirst().forEach { whole.addLine(to: $0) }
        outline.right.reversed().forEach { whole.addLine(to: $0) }
        whole.closeSubpath()
        let cream = Theme.CanvasColors.cream.cgColor
        let halo = CAShapeLayer()
        halo.path = whole; halo.fillColor = cream
        halo.shadowColor = NSColor.black.cgColor; halo.shadowOpacity = 0.35; halo.shadowRadius = 1.5; halo.shadowOffset = .zero
        let fill = CAShapeLayer()
        fill.path = whole; fill.fillColor = cream; fill.strokeColor = cream; fill.lineWidth = 1; fill.lineJoin = .round; fill.lineCap = .round
        let reference = CALayer()
        reference.addSublayer(halo); reference.addSublayer(fill)

        for scale in [CGFloat(1), 2] {
            let drawn = rendered(stroke, size: canvas.bounds.size, scale: scale)
            let expected = rendered(reference, size: canvas.bounds.size, scale: scale)
            var worst = 0, off = 0, inked = 0
            for i in drawn.indices where i % 4 != 3 {
                let d = abs(Int(drawn[i]) - Int(expected[i]))
                worst = max(worst, d)
                if d > 2 { off += 1 }
                if drawn[i] != 255 || expected[i] != 255 { inked += 1 }
            }
            XCTAssertGreaterThan(inked, 10_000, "the ribbon is drawn at \(scale)x")
            XCTAssertLessThanOrEqual(worst, 25, "no channel more than 10 % off at \(scale)x")
            XCTAssertLessThan(off * 100, inked, "under 1 % of the ribbon's channels off at \(scale)x: \(off) of \(inked)")
        }
    }

    /// `layer` drawn on white at `scale`, as RGBA bytes.
    private func rendered(_ layer: CALayer, size: CGSize, scale: CGFloat) -> [UInt8] {
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data
        else { XCTFail("no bitmap context"); return [] }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: w * h * 4))
    }

    /// The ribbon as the canvas drew it whole before pieces (`InkCanvasView.ribbon(for:)` at f182a34), returning its two
    /// edges, with the smoothing as `InkGeometry.smooth` was then: the reference the pieces must match point for point.
    private func wholeOutline(_ pts: [StrokePoint], baseWidth: Float, size: CGSize) -> (left: [CGPoint], right: [CGPoint]) {
        let w = size.width, h = size.height
        var widths: [CGFloat] = []
        var smoothed: Float = baseWidth
        for i in 0..<pts.count {
            let speed = i == 0 ? 0 : InkGeometry.speed(from: pts[i - 1], to: pts[i])
            let target = InkGeometry.width(base: baseWidth * pts[i].pressure, speedPerMs: speed)
            smoothed += (target - smoothed) * 0.3
            widths.append(CGFloat(smoothed))
        }
        let center = wholeSmooth(pts).map { CGPoint(x: CGFloat($0.x) * w, y: CGFloat($0.y) * h) }
        var left: [CGPoint] = [], right: [CGPoint] = []
        for i in 0..<center.count {
            let a = center[max(0, i - 1)], b = center[min(center.count - 1, i + 1)]
            var nx = -(b.y - a.y), ny = b.x - a.x
            let len = max(hypot(nx, ny), 0.0001); nx /= len; ny /= len
            let half = widths[min(widths.count - 1, i * (widths.count - 1) / max(1, center.count - 1))] / 2
            left.append(CGPoint(x: center[i].x + nx * half, y: center[i].y + ny * half))
            right.append(CGPoint(x: center[i].x - nx * half, y: center[i].y - ny * half))
        }
        return (left, right)
    }

    private func wholeSmooth(_ pts: [StrokePoint]) -> [SIMD2<Float>] {
        let p = pts.map { SIMD2($0.x, $0.y) }
        guard p.count > 1 else { return p }
        var out: [SIMD2<Float>] = [p[0]]
        for i in 0..<(p.count - 1) {
            let p0 = i == 0 ? p[0] : p[i - 1]
            let p1 = p[i], p2 = p[i + 1]
            let p3 = i + 2 < p.count ? p[i + 2] : p[i + 1]
            for s in 1...6 {
                let t = Float(s) / 6
                let t2 = t * t, t3 = t2 * t
                let a: SIMD2<Float> = 2 * p1
                let b: SIMD2<Float> = (p2 - p0) * t
                let c: SIMD2<Float> = (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2
                let d: SIMD2<Float> = (3 * p1 - 3 * p2 + p3 - p0) * t3
                let v: SIMD2<Float> = 0.5 * (a + b + c + d)
                out.append(s == 6 ? p2 : v)
            }
        }
        return out
    }

    /// The two edges of a ribbon piece's closed path: it moves to the first left point, runs along the left edge, then
    /// back along the right.
    private func edges(of path: CGPath) -> (left: [CGPoint], right: [CGPoint]) {
        var points: [CGPoint] = []
        var closed = false
        path.applyWithBlock { element in
            switch element.pointee.type {
            case .moveToPoint, .addLineToPoint: points.append(element.pointee.points[0])
            case .closeSubpath: closed = true
            default: XCTFail("a ribbon is straight lines")
            }
        }
        XCTAssertTrue(closed, "a piece is closed")
        let k = points.count / 2
        return (Array(points[..<k]), Array(points[k...].reversed()))
    }
}
