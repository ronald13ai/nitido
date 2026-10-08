import XCTest
@testable import NitidoCore

final class ClockOffsetFilterTests: XCTestCase {
    /// The pong that took the least time is the one least delayed by queueing: its offset wins over newer, slower ones.
    func testTheLowestRTTInTheWindowGivesTheOffset() {
        var f = ClockOffsetFilter()
        f.add(rttMs: 10, offsetNs: 100, at: 0)
        f.add(rttMs: 50, offsetNs: 80, at: 0.5)
        f.add(rttMs: 30, offsetNs: 90, at: 1)
        XCTAssertEqual(f.offsetNs(now: 1), 100)
    }

    /// Once the fastest pong is more than 10 s old, the estimate comes from the fastest one left.
    func testAPongOlderThanTenSecondsNoLongerCounts() {
        var f = ClockOffsetFilter()
        f.add(rttMs: 10, offsetNs: 100, at: 0)
        f.add(rttMs: 50, offsetNs: 80, at: 0.5)
        f.add(rttMs: 30, offsetNs: 90, at: 1)
        XCTAssertEqual(f.offsetNs(now: 10), 100, "exactly 10 s old is still in the window")
        XCTAssertEqual(f.offsetNs(now: 10.25), 90)
        f.add(rttMs: 40, offsetNs: 70, at: 10.75)
        XCTAssertEqual(f.offsetNs(now: 10.75), 90)
        XCTAssertEqual(f.offsetNs(now: 11.25), 70, "only the 40 ms pong is left")
    }

    func testTheNewestPongWinsATie() {
        var f = ClockOffsetFilter()
        f.add(rttMs: 10, offsetNs: 100, at: 0)
        f.add(rttMs: 10, offsetNs: 120, at: 0.5)
        XCTAssertEqual(f.offsetNs(now: 0.5), 120)
    }

    func testNoPongGivesNoOffset() {
        var f = ClockOffsetFilter()
        XCTAssertNil(f.offsetNs(now: 0))
        f.add(rttMs: 10, offsetNs: 100, at: 0)
        XCTAssertNil(f.offsetNs(now: 10.5), "every pong is older than 10 s")
    }
}
