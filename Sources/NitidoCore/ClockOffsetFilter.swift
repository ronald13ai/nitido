import Foundation

/// NTP's minimum-delay filter for the peer's clock offset (spec section 5). One ping/pong gives the offset plus half
/// the difference between the two one-way delays, and video queued in one direction makes that difference large. The
/// pong with the lowest RTT spent the least time queued, so the estimate is its offset, taken over the last 10 s. Times
/// are seconds; samples must arrive in non-decreasing time order.
public struct ClockOffsetFilter: Sendable {
    /// How long a pong counts.
    static let seconds: Double = 10

    private struct Sample: Sendable { var t: Double, rttMs: Double, offsetNs: Int64 }
    private var samples: [Sample] = []

    public init() {}

    public mutating func add(rttMs: Double, offsetNs: Int64, at t: Double) {
        samples.append(Sample(t: t, rttMs: rttMs, offsetNs: offsetNs))
        let cutoff = t - Self.seconds
        samples.removeAll { $0.t < cutoff }
    }

    /// The offset of the lowest-RTT pong of the 10 s up to `now`, the newest of them on a tie; nil when there is none.
    public func offsetNs(now: Double) -> Int64? {
        let cutoff = now - Self.seconds
        var best: Sample?
        for s in samples where s.t >= cutoff && s.rttMs <= (best?.rttMs ?? .infinity) { best = s }
        return best?.offsetNs
    }
}
