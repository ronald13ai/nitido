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

    func testEmptySnapshotHasNils() {
        let s = Telemetry(now: 0).snapshot(now: 0)
        XCTAssertNil(s.latencyMs); XCTAssertNil(s.rttMs); XCTAssertEqual(s.bitrateMbps, 0); XCTAssertEqual(s.captureFPS, 0)
    }
}
