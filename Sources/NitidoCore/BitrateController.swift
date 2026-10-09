import Foundation

/// Deterministic bitrate policy (spec section 8). Call `update` every 250 ms. Congestion cuts the rate by 25%, then
/// holds it for 2 s so the cut can take effect; a healthy link raises it by 10% once the last change, up or down, is
/// 2 s old. Only a cut holds off a cut: congestion right after a raise cuts at once, and frames the sender skipped for
/// its backlog cut at once even within the hold (`skippedForBacklog`).
public struct BitrateController: Sendable {
    public let minimum: Int
    public let maximum: Int
    public private(set) var bitsPerSecond: Int

    private var rttHistory = RollingWindow(seconds: 10)
    private var lastDecrease: Double?
    private var lastChange: Double?

    public init(initial: Int, minimum: Int = 2_000_000, maximum: Int = 60_000_000) {
        self.minimum = minimum; self.maximum = maximum
        self.bitsPerSecond = Swift.max(minimum, Swift.min(maximum, initial))
    }

    /// 20 Mbps at 1080p, scaled by pixel count, clamped to the default bounds.
    public static func initialBitrate(width: Int, height: Int) -> Int {
        let bps = 20_000_000 * Double(width * height) / (1920 * 1080)
        return Swift.max(2_000_000, Swift.min(60_000_000, Int(bps)))
    }

    /// The rate to encode at from now on. `rttMs` is the RTT p50 of the last second, `backlogBytes` the link's send
    /// backlog (the measure the sender's dropping rule judges: without the keyframe on its way), `frameAgeMs`
    /// the age of the newest frame the viewer reported (nil when unknown); `now` is in seconds. `skippedForBacklog`
    /// says the sender started skipping frames for its backlog since the last update (`BacklogPolicy.takeTrip`): the
    /// backlog lasted 100 ms over 150 ms worth, or passed a second's worth, so it cuts now, whatever the other inputs
    /// say and even within the hold of an earlier cut, and the hold counts again from this cut.
    public mutating func update(rttMs: Double?, backlogBytes: Int, frameAgeMs: Double?, fps: Double, now: Double,
                                skippedForBacklog: Bool = false) -> Int {
        if let rttMs { rttHistory.add(rttMs, at: now) }
        let baseline = rttHistory.stats(now: now)?.min
        let frameBytes = Double(bitsPerSecond) / 8 / Swift.max(fps, 1)

        let rttTooHigh = rttMs.flatMap { r in baseline.map { r > $0 + 40 } } ?? false
        let rttHealthy = rttMs.flatMap { r in baseline.map { r <= $0 + 15 } } ?? true
        let stale = (frameAgeMs ?? 0) > 150
        let congested = skippedForBacklog || Double(backlogBytes) > 2 * frameBytes || rttTooHigh || stale
        let healthy = Double(backlogBytes) < frameBytes && rttHealthy && !stale

        if congested {
            if !skippedForBacklog, let cut = lastDecrease, now - cut < 2 { return bitsPerSecond }
            bitsPerSecond = Swift.max(minimum, bitsPerSecond * 3 / 4); lastDecrease = now; lastChange = now
        } else if healthy {
            if let last = lastChange, now - last < 2 { return bitsPerSecond }
            bitsPerSecond = Swift.min(maximum, bitsPerSecond * 11 / 10); lastChange = now
        }
        return bitsPerSecond
    }
}
