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
