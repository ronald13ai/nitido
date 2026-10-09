import XCTest
@testable import NitidoCore

final class BacklogPolicyTests: XCTestCase {
    /// 20 Mbps: a frame is 41 666 bytes at 60 fps, four are 166 664, 150 ms is 375 000 and a second 2 500 000.
    private let rate = 20_000_000
    private let interval = 1.0 / 60

    /// Deltas every frame interval from `from` up to, not including, `until`, each with `backlog` bytes waiting.
    private func deltas(_ p: inout BacklogPolicy, backlog: Int, from: Double, until: Double) -> [BacklogPolicy.Decision] {
        var decisions: [BacklogPolicy.Decision] = []
        var t = from
        while t < until - 1e-9 {
            decisions.append(p.delta(backlogBytes: backlog, bitsPerSecond: rate, now: t))
            t += interval
        }
        return decisions
    }

    /// Fails unless `decision` starts a skip after the backlog had been over the threshold for `seconds`.
    private func assertTrip(_ decision: BacklogPolicy.Decision, after seconds: Double, _ message: String = "",
                            file: StaticString = #filePath, line: UInt = #line) {
        guard case .trip(let overFor) = decision else {
            return XCTFail("\(decision) is not a trip \(message)", file: file, line: line)
        }
        XCTAssertEqual(overFor, seconds, accuracy: 1e-6, message, file: file, line: line)
    }

    func testTheThresholdIsInTimeAndTheCeilingIsASecond() {
        XCTAssertEqual(BacklogPolicy.frameBytes(bitsPerSecond: rate), 41_666)
        XCTAssertEqual(BacklogPolicy.threshold(bitsPerSecond: rate), 375_000, "150 ms worth, more than four frames")
        XCTAssertEqual(BacklogPolicy.ceiling(bitsPerSecond: rate), 2_500_000)
        XCTAssertEqual(BacklogPolicy.threshold(bitsPerSecond: 2_000_000), 37_500)
        XCTAssertEqual(BacklogPolicy.ceiling(bitsPerSecond: 2_000_000), 250_000)
    }

    /// The two-Mac test of 2026-10-09: a Wi-Fi burst or a keyframe left more than the threshold waiting for a moment,
    /// and the old rule skipped at the first reading over it. A backlog that drains within 100 ms skips nothing, asks
    /// for no keyframe and tells the bitrate controller nothing.
    func testABacklogThatDrainsWithinAHundredMillisecondsSkipsNothing() {
        var p = BacklogPolicy()
        let over = deltas(&p, backlog: 500_000, from: 10, until: 10.09)
        XCTAssertEqual(over, Array(repeating: .send, count: 6))
        XCTAssertEqual(p.delta(backlogBytes: 0, bitsPerSecond: rate, now: 10.1), .send)
        XCTAssertFalse(p.skipping)
        XCTAssertFalse(p.keyframeDue(backlogBytes: 0, bitsPerSecond: rate, now: 10.1))
        XCTAssertFalse(p.takeTrip())
    }

    /// Over the threshold for 100 ms: the delta that finds it so is skipped and starts the skip, every delta after it
    /// is skipped, the bitrate controller hears of it once, and the keyframe is asked for once the backlog is under a
    /// frame, then again only after a second without one; the keyframe ends the skip.
    func testABacklogOverTheThresholdForAHundredMillisecondsSkipsUntilAKeyframe() {
        var p = BacklogPolicy()
        XCTAssertEqual(deltas(&p, backlog: 500_000, from: 10, until: 10.09), Array(repeating: .send, count: 6))
        assertTrip(p.delta(backlogBytes: 500_000, bitsPerSecond: rate, now: 10.1), after: 0.1,
                   "the reading 100 ms after the first one over the threshold starts the skip")
        XCTAssertTrue(p.takeTrip())
        XCTAssertFalse(p.takeTrip(), "once per skip")
        XCTAssertEqual(p.delta(backlogBytes: 100_000, bitsPerSecond: rate, now: 10.12), .skip, "draining, still over a frame")
        XCTAssertFalse(p.keyframeDue(backlogBytes: 100_000, bitsPerSecond: rate, now: 10.12))
        XCTAssertEqual(p.delta(backlogBytes: 0, bitsPerSecond: rate, now: 10.13), .skip, "no delta before the keyframe")
        XCTAssertEqual(p.skipped, 3)
        XCTAssertEqual(p.trippedAt, 10.1)
        XCTAssertTrue(p.keyframeDue(backlogBytes: 0, bitsPerSecond: rate, now: 10.13))
        XCTAssertFalse(p.keyframeDue(backlogBytes: 0, bitsPerSecond: rate, now: 11.0), "asked once")
        XCTAssertTrue(p.keyframeDue(backlogBytes: 0, bitsPerSecond: rate, now: 11.13), "again after a second without one")
        p.keyframeSent(now: 11.2)
        XCTAssertFalse(p.skipping)
        XCTAssertFalse(p.keyframeDue(backlogBytes: 0, bitsPerSecond: rate, now: 12.5))
        XCTAssertEqual(p.delta(backlogBytes: 0, bitsPerSecond: rate, now: 11.22), .send)
    }

    /// A reading at or under the threshold starts the 100 ms again, the 250 ms loop's readings (`observe`) included.
    func testAReadingUnderTheThresholdStartsTheHundredMillisecondsAgain() {
        var p = BacklogPolicy()
        XCTAssertEqual(p.delta(backlogBytes: 500_000, bitsPerSecond: rate, now: 10), .send)
        XCTAssertEqual(p.delta(backlogBytes: 500_000, bitsPerSecond: rate, now: 10.05), .send)
        p.observe(backlogBytes: 375_000, bitsPerSecond: rate, now: 10.06)
        XCTAssertEqual(p.delta(backlogBytes: 500_000, bitsPerSecond: rate, now: 10.07), .send)
        XCTAssertEqual(p.delta(backlogBytes: 500_000, bitsPerSecond: rate, now: 10.16), .send, "over for 90 ms only")
        assertTrip(p.delta(backlogBytes: 500_000, bitsPerSecond: rate, now: 10.17), after: 0.1)
    }

    /// A reading of the 250 ms loop starts the 100 ms too: a source that changed again after a pause skips its first
    /// delta when the backlog has been over the threshold since the loop saw it.
    func testTheLoopsReadingCountsTowardsTheHundredMilliseconds() {
        var p = BacklogPolicy()
        p.observe(backlogBytes: 500_000, bitsPerSecond: rate, now: 10)
        p.observe(backlogBytes: 500_000, bitsPerSecond: rate, now: 10.25)
        assertTrip(p.delta(backlogBytes: 500_000, bitsPerSecond: rate, now: 10.3), after: 0.3)
    }

    /// Over a second's worth the deltas are skipped at the first reading.
    func testABacklogOverTheCeilingSkipsAtOnce() {
        var p = BacklogPolicy()
        assertTrip(p.delta(backlogBytes: 2_500_001, bitsPerSecond: rate, now: 10), after: 0)
        XCTAssertTrue(p.takeTrip())
    }

    /// For half a second after the keyframe that ended a skip, a backlog over the threshold skips nothing, however long
    /// it stays (the keyframe's own bytes are not in it, and a link that is still recovering gets the time to); one
    /// over the ceiling still skips at once. After the half second the 100 ms rule is back, counted from the first
    /// reading over the threshold, in the half second or not.
    func testAfterTheKeyframeOnlyTheCeilingSkipsForHalfASecond() {
        func recovered(at t: Double) -> BacklogPolicy {
            var p = BacklogPolicy()
            _ = p.delta(backlogBytes: 2_500_001, bitsPerSecond: rate, now: t - 0.2)
            _ = p.takeTrip()
            XCTAssertTrue(p.keyframeDue(backlogBytes: 0, bitsPerSecond: rate, now: t - 0.05))
            p.keyframeSent(now: t)
            return p
        }
        var p = recovered(at: 10)
        let held = deltas(&p, backlog: 500_000, from: 10.01, until: 10.5)
        XCTAssertEqual(held, Array(repeating: .send, count: held.count))
        XCTAssertEqual(held.count, 30)
        XCTAssertFalse(p.takeTrip())
        assertTrip(p.delta(backlogBytes: 500_000, bitsPerSecond: rate, now: 10.51), after: 0.5, "the hold-off is over")

        var q = recovered(at: 20)
        XCTAssertEqual(q.delta(backlogBytes: 500_000, bitsPerSecond: rate, now: 20.2), .send)
        assertTrip(q.delta(backlogBytes: 2_500_001, bitsPerSecond: rate, now: 20.21), after: 0.01)
    }

    /// A keyframe that ends no skip (the encoder's own every 120 frames, or one a viewer asked for) starts no hold-off.
    func testAKeyframeOutsideASkipChangesNothing() {
        var p = BacklogPolicy()
        p.keyframeSent(now: 10)
        XCTAssertEqual(p.delta(backlogBytes: 500_000, bitsPerSecond: rate, now: 10.01), .send)
        assertTrip(p.delta(backlogBytes: 500_000, bitsPerSecond: rate, now: 10.11), after: 0.1)
    }

    /// The rule follows the rate: at 2 Mbps, where the codec loop's floor and a small window sit, 150 KB is 600 ms
    /// worth, over the threshold and under the ceiling, so it skips only once it has lasted 100 ms.
    func testTheThresholdFollowsTheRate() {
        var p = BacklogPolicy()
        XCTAssertEqual(p.delta(backlogBytes: 150_000, bitsPerSecond: 2_000_000, now: 10), .send)
        assertTrip(p.delta(backlogBytes: 150_000, bitsPerSecond: 2_000_000, now: 10.1), after: 0.1)
        var q = BacklogPolicy()
        assertTrip(q.delta(backlogBytes: 250_001, bitsPerSecond: 2_000_000, now: 10), after: 0)
    }
}
