import XCTest
@testable import NitidoCore

final class TelemetryTests: XCTestCase {
    func testWindowDropsOldSamples() {
        var w = RollingWindow(seconds: 1)
        w.add(1, at: 0); w.add(2, at: 0.5); w.add(3, at: 1.2)
        XCTAssertEqual(w.values(now: 1.2), [2, 3])     // the sample at t=0 is older than 1 s
        XCTAssertEqual(w.count(now: 2.6), 0)
        XCTAssertNil(w.stats(now: 2.6))
    }

    func testPercentilesUseNearestRank() {
        var w = RollingWindow(seconds: 100)
        for v in 1...100 { w.add(Double(v), at: 0) }
        let s = w.stats(now: 0)!
        XCTAssertEqual(s.count, 100); XCTAssertEqual(s.min, 1); XCTAssertEqual(s.max, 100)
        XCTAssertEqual(s.mean, 50.5, accuracy: 0.001)
        XCTAssertEqual(s.p50, 50); XCTAssertEqual(s.p95, 95)
    }

    func testFramesPerSecondIsCountInLastSecond() {
        var t = Telemetry(now: 0)
        for i in 0..<60 { t.recordCapture(at: Double(i) / 60) }
        for i in 0..<30 { t.recordDisplay(at: Double(i) / 30) }
        let s = t.snapshot(now: 0.999)
        XCTAssertEqual(s.captureFPS, 60); XCTAssertEqual(s.displayFPS, 30)
        XCTAssertEqual(t.snapshot(now: 2.5).captureFPS, 0)
    }

    func testLatencyRTTBitrateAndDrops() {
        var t = Telemetry(now: 0)
        for v in [10.0, 12, 11, 40, 12] { t.recordLatency(ms: v, at: 0.5) }
        // Nearest-rank p50 of [8, 10, 30] is 10, distinct from min, max, mean and the latest sample.
        t.recordRTT(ms: 8, at: 0.5); t.recordRTT(ms: 10, at: 0.6); t.recordRTT(ms: 30, at: 0.65)
        t.recordBytes(1_250_000, at: 0.7)            // 10 Mbit in the last second
        t.recordDrop(at: 0.8); t.recordDrop(at: 0.9)
        let s = t.snapshot(now: 1.0)
        XCTAssertEqual(s.latencyMs, 12); XCTAssertEqual(s.latencyP95Ms, 40)
        XCTAssertEqual(s.rttMs, 10)
        XCTAssertEqual(s.bitrateMbps, 10, accuracy: 0.001)
        XCTAssertEqual(s.droppedLastSecond, 2)
        XCTAssertEqual(s.latencySeries.count, 5)
    }

    /// The sparkline's latency is bucketed in time, 50 ms a bucket on a fixed grid: the median of each, a gap where no
    /// frame came, the newest bucket the one `now` falls in, and the same bucket the same at the next snapshot.
    func testLatencyBucketsAreInTime() {
        var t = Telemetry(now: 0)
        for (ms, at) in [(30.0, 10.001), (50, 10.02), (40, 10.03), (70, 10.12), (60, 10.249)] { t.recordLatency(ms: ms, at: at) }
        let s = t.snapshot(now: 10.249)
        XCTAssertEqual(s.latencyBuckets.count, Snapshot.bucketCount)
        XCTAssertEqual(s.newestBucket, 204)
        let last = Array(s.latencyBuckets.suffix(5))
        XCTAssertEqual(last[0], 40, "10.00 to 10.05: the median of 30, 50, 40")
        XCTAssertNil(last[1], "10.05 to 10.10: no frame, a gap")
        XCTAssertEqual(last[2], 70)
        XCTAssertNil(last[3])
        XCTAssertEqual(last[4], 60, "the bucket now falls in")
        XCTAssertTrue(s.latencyBuckets.prefix(40).allSatisfy { $0 == nil })
        let next = t.snapshot(now: 10.5)
        XCTAssertEqual(next.newestBucket, 210)
        XCTAssertEqual(next.latencyBuckets[Snapshot.bucketCount - 1 - 6], 60, "bucket 204, six buckets older now")
    }

    /// A snapshot is warm once a full second has been counted since the telemetry began or was reset: before that its
    /// one-second counts cover part of a second, and the strip shows "·" for them. The counts stay raw; a reset empties
    /// the windows and keeps the running total of drops.
    func testASnapshotIsWarmOnceAFullSecondHasBeenCounted() {
        var t = Telemetry(now: 10)
        t.recordCapture(at: 10.2); t.recordDrop(at: 10.3)
        XCTAssertFalse(t.snapshot(now: 10.5).warm, "half a second counted")
        XCTAssertEqual(t.snapshot(now: 10.5).captureFPS, 1, "the raw count, as it is")
        XCTAssertTrue(t.snapshot(now: 11).warm)
        t.recordCapture(at: 19.8); t.recordDrop(at: 19.9)
        t.reset(now: 20)
        let s = t.snapshot(now: 20.5)
        XCTAssertFalse(s.warm, "counting again from the reset")
        XCTAssertEqual(s.captureFPS, 0, "the frame before the reset is not counted")
        XCTAssertEqual(s.droppedLastSecond, 0)
        XCTAssertEqual(t.droppedTotal, 2, "the running total keeps counting")
        XCTAssertEqual(t.countingSince, 20)
        XCTAssertTrue(t.snapshot(now: 21).warm)
        XCTAssertFalse(Snapshot.empty.warm, "nothing counted yet")
    }

    func testEmptySnapshotHasNils() {
        let s = Telemetry(now: 0).snapshot(now: 0)
        XCTAssertNil(s.latencyMs); XCTAssertNil(s.rttMs); XCTAssertEqual(s.bitrateMbps, 0); XCTAssertEqual(s.captureFPS, 0)
    }
}
