import Foundation

public struct Stats: Sendable, Equatable {
    public var count: Int, mean: Double, min: Double, max: Double, p50: Double, p95: Double
}

/// Time-bounded sample buffer. Times are seconds; samples must arrive in non-decreasing time order.
public struct RollingWindow: Sendable {
    public let seconds: Double
    private var times: [Double] = []
    private var values: [Double] = []

    public init(seconds: Double) { self.seconds = seconds }

    public mutating func add(_ value: Double, at t: Double) {
        times.append(t); values.append(value); prune(now: t)
    }

    public mutating func prune(now: Double) {
        let cutoff = now - seconds
        var drop = 0
        while drop < times.count, times[drop] < cutoff { drop += 1 }
        if drop > 0 { times.removeFirst(drop); values.removeFirst(drop) }
    }

    public func values(now: Double) -> [Double] {
        let cutoff = now - seconds
        return zip(times, values).filter { $0.0 >= cutoff }.map(\.1)
    }

    public func count(now: Double) -> Int { values(now: now).count }

    public func stats(now: Double) -> Stats? {
        let v = values(now: now).sorted()
        guard !v.isEmpty else { return nil }
        func rank(_ p: Double) -> Double { v[max(0, min(v.count - 1, Int((p * Double(v.count)).rounded(.up)) - 1))] }
        return Stats(count: v.count, mean: v.reduce(0, +) / Double(v.count), min: v[0], max: v[v.count - 1],
                     p50: rank(0.5), p95: rank(0.95))
    }
}

public struct Snapshot: Sendable, Equatable {
    public var captureFPS: Double
    public var displayFPS: Double
    public var latencyMs: Double?
    public var latencyP95Ms: Double?
    public var rttMs: Double?
    public var bitrateMbps: Double
    public var droppedLastSecond: Int
    /// Latency samples of the last two seconds, oldest first, for the sparkline.
    public var latencySeries: [Double]
    public static let empty = Snapshot(captureFPS: 0, displayFPS: 0, latencyMs: nil, latencyP95Ms: nil, rttMs: nil,
                                       bitrateMbps: 0, droppedLastSecond: 0, latencySeries: [])
}

public struct Telemetry: Sendable {
    private var captures = RollingWindow(seconds: 1)
    private var displays = RollingWindow(seconds: 1)
    private var latency = RollingWindow(seconds: 1)
    private var latencySeries = RollingWindow(seconds: 2)
    private var rtt = RollingWindow(seconds: 1)
    private var bytes = RollingWindow(seconds: 1)
    private var drops = RollingWindow(seconds: 1)
    /// Every dropped frame recorded so far, not only the last second's: what a check that must not depend on when the
    /// snapshot is taken reads.
    public private(set) var droppedTotal = 0

    public init(now: Double) {}

    public mutating func recordCapture(at t: Double) { captures.add(1, at: t) }
    public mutating func recordDisplay(at t: Double) { displays.add(1, at: t) }
    public mutating func recordLatency(ms: Double, at t: Double) { latency.add(ms, at: t); latencySeries.add(ms, at: t) }
    public mutating func recordRTT(ms: Double, at t: Double) { rtt.add(ms, at: t) }
    public mutating func recordBytes(_ n: Int, at t: Double) { bytes.add(Double(n), at: t) }
    public mutating func recordDrop(at t: Double) { drops.add(1, at: t); droppedTotal += 1 }

    public func snapshot(now: Double) -> Snapshot {
        let lat = latency.stats(now: now)
        let bits = bytes.values(now: now).reduce(0, +) * 8
        return Snapshot(captureFPS: Double(captures.count(now: now)),
                        displayFPS: Double(displays.count(now: now)),
                        latencyMs: lat?.p50, latencyP95Ms: lat?.p95,
                        rttMs: rtt.stats(now: now)?.p50,
                        bitrateMbps: bits / 1_000_000,
                        droppedLastSecond: drops.count(now: now),
                        latencySeries: latencySeries.values(now: now))
    }
}
