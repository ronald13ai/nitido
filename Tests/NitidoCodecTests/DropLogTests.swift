import XCTest
@testable import NitidoCodec

final class DropLogTests: XCTestCase {
    /// The evening two-Mac test of 2026-10-09 logged "encoder dropped frame N, flags 3: frameDropped" as an error ten
    /// times in a row. A realtime encoder under load lets frames go, and that is said at info, at most once a second:
    /// the first drop at once, then the ones since in one line once a second has passed.
    func testDropsAreLoggedAtOnceThenAtMostOnceASecond() {
        var log = DropLog()
        XCTAssertEqual(log.dropped(now: 10), 1, "the first drop is logged at once")
        for step in 1...9 { XCTAssertNil(log.dropped(now: 10 + Double(step) / 10), "within the second") }
        XCTAssertEqual(log.dropped(now: 11), 10, "the nine held and this one, in one line")
        XCTAssertNil(log.dropped(now: 11.5))
        XCTAssertEqual(log.dropped(now: 13), 2, "a second or more later")
    }
}
