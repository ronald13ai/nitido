import XCTest
@testable import NitidoCore

final class InkTests: XCTestCase {
    private func pt(_ x: Float, _ y: Float, _ t: UInt32 = 0) -> StrokePoint { StrokePoint(x: x, y: y, pressure: 1, tMs: t) }

    func testSmoothKeepsEndpointsAndAddsPoints() {
        let pts = [pt(0, 0), pt(0.5, 0.2), pt(1, 0)]
        let out = InkGeometry.smooth(pts, segments: 4)
        XCTAssertEqual(out.first, SIMD2(0, 0)); XCTAssertEqual(out.last, SIMD2(1, 0))
        XCTAssertEqual(out.count, 9)   // 2 spans x 4 segments + 1
        XCTAssertEqual(InkGeometry.smooth([pt(0.3, 0.3)], segments: 4), [SIMD2(0.3, 0.3)])
        XCTAssertEqual(InkGeometry.smooth([], segments: 4), [])
    }

    func testWidthThinsWithSpeedAndClamps() {
        XCTAssertEqual(InkGeometry.width(base: 4, speedPerMs: 0), 4.8, accuracy: 0.001)
        XCTAssertLessThan(InkGeometry.width(base: 4, speedPerMs: 0.001), InkGeometry.width(base: 4, speedPerMs: 0))
        XCTAssertEqual(InkGeometry.width(base: 4, speedPerMs: 10), 1.4, accuracy: 0.001)
        XCTAssertEqual(InkGeometry.speed(from: pt(0, 0, 0), to: pt(0.3, 0.4, 10)), 0.05, accuracy: 0.0001)
    }

    func testApplyBuildsAStrokeAndUndoPopsOnlyLocal() {
        var doc = InkDocument()
        let local = doc.allocateId(role: .share); let remote: UInt32 = 1
        doc.apply(StrokeMessage(strokeId: local, phase: .begin, color: .gold, baseWidth: 3, points: [pt(0, 0)]), isRemote: false, now: 0)
        doc.apply(StrokeMessage(strokeId: local, phase: .append, color: .gold, baseWidth: 3, points: [pt(0.1, 0.1, 5), pt(0.2, 0.2, 9)]), isRemote: false, now: 0.01)
        doc.apply(StrokeMessage(strokeId: remote, phase: .begin, color: .cream, baseWidth: 3, points: [pt(0.5, 0.5)]), isRemote: true, now: 0.02)
        doc.apply(StrokeMessage(strokeId: local, phase: .end, color: .gold, baseWidth: 3, points: []), isRemote: false, now: 0.03)
        XCTAssertEqual(doc.strokes.count, 2)
        XCTAssertEqual(doc.strokes[0].points.count, 3); XCTAssertEqual(doc.strokes[0].endedAt, 0.03)
        XCTAssertEqual(doc.undoLastLocal(), local)
        XCTAssertEqual(doc.strokes.map(\.id), [remote])
        XCTAssertNil(doc.undoLastLocal())
        doc.apply(StrokeMessage(strokeId: 99, phase: .append, color: .gold, baseWidth: 3, points: [pt(0, 0)]), isRemote: true, now: 1)
        XCTAssertEqual(doc.strokes.count, 1, "append for an unknown id is ignored")
    }

    func testIdsNeverCollideBetweenRoles() {
        var a = InkDocument(), b = InkDocument()
        let ids = (0..<5).map { _ in a.allocateId(role: .share) } + (0..<5).map { _ in b.allocateId(role: .view) }
        XCTAssertEqual(Set(ids).count, 10)
        XCTAssertTrue(a.allocateId(role: .share) % 2 == 0); XCTAssertTrue(b.allocateId(role: .view) % 2 == 1)
    }

    func testOpacityFadesFourSecondsAfterEndOverSixHundredMs() {
        var doc = InkDocument()
        let id = doc.allocateId(role: .view)
        doc.apply(StrokeMessage(strokeId: id, phase: .begin, color: .gold, baseWidth: 3, points: [pt(0, 0)]), isRemote: false, now: 10)
        XCTAssertEqual(doc.opacity(of: doc.strokes[0], now: 100), 1, "an unfinished stroke never fades")
        doc.apply(StrokeMessage(strokeId: id, phase: .end, color: .gold, baseWidth: 3, points: []), isRemote: false, now: 10)
        let s = doc.strokes[0]
        XCTAssertEqual(doc.opacity(of: s, now: 13.9), 1)
        XCTAssertEqual(doc.opacity(of: s, now: 14.3), 0.5, accuracy: 0.001)
        XCTAssertEqual(doc.opacity(of: s, now: 14.6), 0)
        doc.prune(now: 14.7)
        XCTAssertTrue(doc.strokes.isEmpty)
    }

    /// A peer's stroke whose end never comes (its link dropped mid-stroke, so the `.end` was lost) is ended when the link
    /// drops, and fades four seconds later like any other; the strokes already ended, and this side's own, keep theirs.
    func testRemoteStrokesStillBeingDrawnEndWhenTheirLinkDrops() {
        var doc = InkDocument()
        doc.apply(StrokeMessage(strokeId: 1, phase: .begin, color: .cream, baseWidth: 3, points: [pt(0, 0)]), isRemote: true, now: 10)
        doc.apply(StrokeMessage(strokeId: 3, phase: .begin, color: .cream, baseWidth: 3, points: [pt(0, 0)]), isRemote: true, now: 10)
        doc.apply(StrokeMessage(strokeId: 3, phase: .end, color: .cream, baseWidth: 3, points: []), isRemote: true, now: 11)
        doc.apply(StrokeMessage(strokeId: 2, phase: .begin, color: .gold, baseWidth: 3, points: [pt(0, 0)]), isRemote: false, now: 10)
        doc.endRemoteStrokes(now: 20)
        XCTAssertEqual(doc.strokes.map(\.endedAt), [20, 11, nil])
        XCTAssertEqual(doc.opacity(of: doc.strokes[0], now: 24.3), 0.5, accuracy: 0.001)
    }

    func testClearRemovesEverything() {
        var doc = InkDocument()
        doc.apply(StrokeMessage(strokeId: 2, phase: .begin, color: .gold, baseWidth: 3, points: [pt(0, 0)]), isRemote: false, now: 0)
        doc.clear()
        XCTAssertTrue(doc.strokes.isEmpty)
    }
}
