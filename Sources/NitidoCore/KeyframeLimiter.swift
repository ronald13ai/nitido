import Foundation

/// At most one keyframe forced for a viewer per `interval` (spec section 8): the ones it asks for (`keyframeRequest`)
/// and the sharer's own (the drain after a skip, a viewer that reconnects). A keyframe is the largest thing the encoder
/// makes, and one forced after another fills the link it is meant to clear: on the evening two-Mac test of 2026-10-09 a
/// storm of them made VideoToolbox drop ten frames in a row. The first ask goes at once; one inside the interval is due
/// when the interval is up, and every ask until then is folded into it, so none is lost and none waits longer than the
/// interval. A keyframe that went out after the last ask folded in answers it, and the one due is not forced. A new
/// viewer starts with a fresh limiter, so its first keyframe is never held. Times are in seconds.
public struct KeyframeLimiter: Sendable {
    /// The shortest time between two forced keyframes.
    public static let interval = 0.5
    /// Asks a few nanoseconds short of the interval, from adding up times in seconds, still count as past it.
    private static let slack = 1e-6

    public enum Answer: Equatable, Sendable {
        /// Force a keyframe now.
        case now
        /// Force one at this time, unless a keyframe goes out before then (`due`).
        case at(Double)
        /// One is due already; this ask is folded into it.
        case folded
    }

    /// When the last keyframe was forced.
    private var forcedAt: Double?
    /// The latest ask folded into the keyframe due; nil while none is.
    private var askedAt: Double?

    public init() {}

    /// When the keyframe due is to be forced: the time the first ask held was answered with (`.at`), which every ask
    /// folded into it shares; nil while none is due.
    public var dueAt: Double? { askedAt == nil ? nil : forcedAt.map { $0 + Self.interval } }

    /// A keyframe is wanted now.
    public mutating func ask(now: Double) -> Answer {
        if askedAt != nil { askedAt = now; return .folded }
        if let last = forcedAt, now - last < Self.interval - Self.slack {
            askedAt = now
            return .at(last + Self.interval)
        }
        forcedAt = now
        return .now
    }

    /// The time `ask` answered with has come. True when the keyframe is to be forced now; false when one went out
    /// (`lastKeyframeAt`) after the last ask it would answer.
    public mutating func due(now: Double, lastKeyframeAt: Double?) -> Bool {
        guard let asked = askedAt else { return false }
        askedAt = nil
        if let sent = lastKeyframeAt, sent >= asked { return false }
        forcedAt = now
        return true
    }
}
