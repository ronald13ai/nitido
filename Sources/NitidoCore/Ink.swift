import Foundation

public struct Stroke: Sendable, Equatable, Identifiable {
    public let id: UInt32
    public var color: RGB
    public var baseWidth: Float
    public var points: [StrokePoint]
    public var isRemote: Bool
    public var startedAt: Double
    public var endedAt: Double?
}

public enum InkGeometry {
    /// Centripetal Catmull-Rom through the points: `segments` interpolated points per span, endpoints kept exactly.
    public static func smooth(_ pts: [StrokePoint], segments: Int = 6) -> [SIMD2<Float>] {
        let p = pts.map { SIMD2($0.x, $0.y) }
        guard p.count > 1 else { return p }
        var out: [SIMD2<Float>] = [p[0]]
        for i in 0..<(p.count - 1) {
            let p0 = i == 0 ? p[0] : p[i - 1]
            let p1 = p[i], p2 = p[i + 1]
            let p3 = i + 2 < p.count ? p[i + 2] : p[i + 1]
            for s in 1...segments {
                let t = Float(s) / Float(segments)
                let t2 = t * t, t3 = t2 * t
                // Split into terms: the single-expression form exceeds the type checker's time limit.
                let a: SIMD2<Float> = 2 * p1
                let b: SIMD2<Float> = (p2 - p0) * t
                let c: SIMD2<Float> = (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2
                let d: SIMD2<Float> = (3 * p1 - 3 * p2 + p3 - p0) * t3
                let v: SIMD2<Float> = 0.5 * (a + b + c + d)
                out.append(s == segments ? p2 : v)
            }
        }
        return out
    }

    /// Fast strokes are thin: width = base * clamp(1.2 - speed * 400, 0.35, 1.2). Speed is picture units per ms.
    public static func width(base: Float, speedPerMs: Float) -> Float {
        base * min(1.2, max(0.35, 1.2 - speedPerMs * 400))
    }

    public static func speed(from a: StrokePoint, to b: StrokePoint) -> Float {
        let d = ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)).squareRoot()
        return d / Float(max(1, Int(b.tMs) - Int(a.tMs)))
    }
}

public struct InkDocument: Sendable, Equatable {
    public private(set) var strokes: [Stroke] = []
    public var fadeAfter: Double = 4
    public var fadeDuration: Double = 0.6
    private var counter: UInt32 = 0

    public init() {}

    /// Share side allocates even ids, view side odd ids, so the two peers never collide.
    public mutating func allocateId(role: Role) -> UInt32 {
        counter += 1
        return counter * 2 + (role == .share ? 0 : 1)
    }

    public mutating func apply(_ m: StrokeMessage, isRemote: Bool, now: Double) {
        switch m.phase {
        case .begin: begin(id: m.strokeId, color: m.color, baseWidth: m.baseWidth, points: m.points, isRemote: isRemote, now: now)
        case .append: append(id: m.strokeId, points: m.points)
        case .end: end(id: m.strokeId, now: now)
        }
    }

    public mutating func begin(id: UInt32, color: RGB, baseWidth: Float, points: [StrokePoint], isRemote: Bool, now: Double) {
        strokes.removeAll { $0.id == id }
        strokes.append(Stroke(id: id, color: color, baseWidth: baseWidth, points: points, isRemote: isRemote, startedAt: now, endedAt: nil))
    }

    public mutating func append(id: UInt32, points: [StrokePoint]) {
        guard let i = strokes.firstIndex(where: { $0.id == id }) else { return }
        strokes[i].points.append(contentsOf: points)
    }

    public mutating func end(id: UInt32, now: Double) {
        guard let i = strokes.firstIndex(where: { $0.id == id }) else { return }
        strokes[i].endedAt = now
    }

    /// Ends every remote stroke still being drawn: its peer's link dropped, and the `.end` it would have sent was lost, so
    /// it fades from `now` like any other (`fadeAfter`).
    public mutating func endRemoteStrokes(now: Double) {
        for i in strokes.indices where strokes[i].isRemote && strokes[i].endedAt == nil { strokes[i].endedAt = now }
    }

    @discardableResult
    public mutating func undoLastLocal() -> UInt32? {
        guard let i = strokes.lastIndex(where: { !$0.isRemote }) else { return nil }
        return strokes.remove(at: i).id
    }

    public mutating func remove(id: UInt32) { strokes.removeAll { $0.id == id } }
    public mutating func clear() { strokes.removeAll() }

    /// 1 while drawing and for `fadeAfter` seconds after the end, then linear to 0 over `fadeDuration`.
    public func opacity(of s: Stroke, now: Double) -> Float {
        guard let end = s.endedAt else { return 1 }
        let t = now - end - fadeAfter
        if t <= 0 { return 1 }
        // Subtract in Float (the return precision) so double rounding residue such as 5.5e-16 at the end of the fade reads as 0.
        return max(0, 1 - Float(t / fadeDuration))
    }

    public mutating func prune(now: Double) {
        let snapshot = self   // the closure cannot read self while strokes is being mutated (exclusivity)
        strokes.removeAll { snapshot.opacity(of: $0, now: now) <= 0 }
    }
}
