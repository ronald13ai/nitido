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

    /// The samples bucketed by time, oldest first: `count` buckets of `width` seconds on a fixed grid (bucket i covers
    /// `[i × width, (i + 1) × width)`), the newest the one `now` falls in; each the median of its samples (the upper of
    /// the two middle ones), nil where none came. A grid fixed in time, not in samples, keeps a picture's sparkline from
    /// stretching with its frame rate, and shows a pause as a gap.
    public func buckets(now: Double, width: Double, count: Int) -> [Double?] {
        let newest = Int((now / width).rounded(.down))
        let first = newest - count + 1
        var grouped = [[Double]](repeating: [], count: count)
        for (t, v) in zip(times, values) {
            let index = Int((t / width).rounded(.down)) - first
            if index >= 0, index < count { grouped[index].append(v) }
        }
        return grouped.map { samples in
            guard !samples.isEmpty else { return nil }
            return samples.sorted()[samples.count / 2]
        }
    }

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
    /// Latency samples of the last two seconds, oldest first.
    public var latencySeries: [Double]
    /// Latency over time for the sparkline: `Snapshot.bucketCount` buckets of `Snapshot.bucketWidth` seconds on a grid
    /// fixed in time, oldest first, the median of each, nil where no frame came; the newest is bucket `newestBucket`
    /// (`RollingWindow.buckets`).
    public var latencyBuckets: [Double?] = []
    public var newestBucket = 0
    public static let bucketWidth = 0.05
    /// Two and a quarter seconds: the two the sparkline shows, and the quarter that slides in until the next snapshot.
    public static let bucketCount = 45
    public static let empty = Snapshot(captureFPS: 0, displayFPS: 0, latencyMs: nil, latencyP95Ms: nil, rttMs: nil,
                                       bitrateMbps: 0, droppedLastSecond: 0, latencySeries: [])
}

public struct Telemetry: Sendable {
    private var captures = RollingWindow(seconds: 1)
    private var displays = RollingWindow(seconds: 1)
    private var latency = RollingWindow(seconds: 1)
    private var latencySeries = RollingWindow(seconds: 2)
    private var latencyTimeline = RollingWindow(seconds: Double(Snapshot.bucketCount) * Snapshot.bucketWidth + Snapshot.bucketWidth)
    private var rtt = RollingWindow(seconds: 1)
    private var bytes = RollingWindow(seconds: 1)
    private var drops = RollingWindow(seconds: 1)
    /// Every dropped frame recorded so far, not only the last second's: what a check that must not depend on when the
    /// snapshot is taken reads.
    public private(set) var droppedTotal = 0

    public init(now: Double) {}

    public mutating func recordCapture(at t: Double) { captures.add(1, at: t) }
    public mutating func recordDisplay(at t: Double) { displays.add(1, at: t) }
    public mutating func recordLatency(ms: Double, at t: Double) {
        latency.add(ms, at: t); latencySeries.add(ms, at: t); latencyTimeline.add(ms, at: t)
    }
    public mutating func recordRTT(ms: Double, at t: Double) { rtt.add(ms, at: t) }
    public mutating func recordBytes(_ n: Int, at t: Double) { bytes.add(Double(n), at: t) }
    public mutating func recordDrop(at t: Double) { drops.add(1, at: t); droppedTotal += 1 }

    public func snapshot(now: Double) -> Snapshot {
        let lat = latency.stats(now: now)
        let bits = bytes.values(now: now).reduce(0, +) * 8
        var snapshot = Snapshot(captureFPS: Double(captures.count(now: now)),
                                displayFPS: Double(displays.count(now: now)),
                                latencyMs: lat?.p50, latencyP95Ms: lat?.p95,
                                rttMs: rtt.stats(now: now)?.p50,
                                bitrateMbps: bits / 1_000_000,
                                droppedLastSecond: drops.count(now: now),
                                latencySeries: latencySeries.values(now: now))
        snapshot.latencyBuckets = latencyTimeline.buckets(now: now, width: Snapshot.bucketWidth, count: Snapshot.bucketCount)
        snapshot.newestBucket = Int((now / Snapshot.bucketWidth).rounded(.down))
        return snapshot
    }
}
