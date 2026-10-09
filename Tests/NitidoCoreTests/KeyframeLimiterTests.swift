import XCTest
@testable import NitidoCore

final class KeyframeLimiterTests: XCTestCase {
    /// The first keyframe forced for a viewer goes at once. One asked for within half a second of it waits until the
    /// half second is up, and every ask in between is folded into that one.
    func testTheFirstIsAtOnceAndTheNextWithinHalfASecondWaitsForIt() {
        var limiter = KeyframeLimiter()
        XCTAssertEqual(limiter.ask(now: 10), .now)
        XCTAssertEqual(limiter.ask(now: 10.1), .at(10.5))
        XCTAssertEqual(limiter.ask(now: 10.2), .folded)
        XCTAssertEqual(limiter.ask(now: 10.45), .folded)
        // The keyframe forced at 10 went out at 10.05, before the asks it would answer.
        XCTAssertTrue(limiter.due(now: 10.5, lastKeyframeAt: 10.05), "forced at 10.5")
        XCTAssertEqual(limiter.ask(now: 10.6), .at(11.0), "half a second after the one forced at 10.5")
        XCTAssertTrue(limiter.due(now: 11.0, lastKeyframeAt: 10.55))
        XCTAssertEqual(limiter.ask(now: 11.5), .now, "half a second after the last forced")
    }

    /// A keyframe that went out after the last ask folded in (the one already asked for of the encoder, or the
    /// encoder's own) answers it: the one due is not forced, and the next ask counts from the last keyframe forced.
    func testAKeyframeThatWentOutAfterTheLastAskAnswersIt() {
        var limiter = KeyframeLimiter()
        XCTAssertEqual(limiter.ask(now: 0), .now)
        XCTAssertEqual(limiter.ask(now: 0.01), .at(0.5), "a viewer that asked as the first was on its way")
        XCTAssertFalse(limiter.due(now: 0.5, lastKeyframeAt: 0.04), "the first keyframe went out after that ask")
        XCTAssertEqual(limiter.ask(now: 0.52), .now, "half a second after the last one forced")
    }

    /// A viewer that asks every 10 ms for three seconds gets at most one forced keyframe per half second, and never
    /// waits longer than that for one.
    func testAStormOfAsksForcesAtMostOneKeyframePerHalfSecond() {
        var limiter = KeyframeLimiter()
        var forced: [Double] = []
        var due: Double?
        for step in 0...300 {
            let now = Double(step) / 100
            if let at = due, now >= at - 1e-9 {
                due = nil
                if limiter.due(now: now, lastKeyframeAt: forced.last.map { $0 + 0.005 }) { forced.append(now) }
            }
            switch limiter.ask(now: now) {
            case .now: forced.append(now)
            case .at(let at): due = at
            case .folded: break
            }
        }
        XCTAssertEqual(forced.count, 7, "\(forced)")
        for (a, b) in zip(forced, forced.dropFirst()) { XCTAssertEqual(b - a, 0.5, accuracy: 1e-6, "\(forced)") }
    }

    /// When the keyframe due is forced (what the drain's log line says, `ShareModel.keyframeAfterDrain`): none while
    /// the asks go at once, the time the first ask held was answered with, the same for every ask folded into it, and
    /// none once it was forced or a keyframe that went out answered it.
    func testTheKeyframeDueSaysWhenItIsForced() {
        var limiter = KeyframeLimiter()
        XCTAssertNil(limiter.dueAt)
        XCTAssertEqual(limiter.ask(now: 10), .now)
        XCTAssertNil(limiter.dueAt, "the one forced at once is not due")
        XCTAssertEqual(limiter.ask(now: 10.1), .at(10.5))
        XCTAssertEqual(limiter.dueAt, 10.5)
        XCTAssertEqual(limiter.ask(now: 10.3), .folded)
        XCTAssertEqual(limiter.dueAt, 10.5, "an ask folded in goes with the one due")
        XCTAssertTrue(limiter.due(now: 10.5, lastKeyframeAt: 10.05))
        XCTAssertNil(limiter.dueAt, "forced")
        XCTAssertEqual(limiter.ask(now: 10.6), .at(11.0))
        XCTAssertEqual(limiter.dueAt, 11.0)
        XCTAssertFalse(limiter.due(now: 11.0, lastKeyframeAt: 10.7))
        XCTAssertNil(limiter.dueAt, "a keyframe that went out answered it")
    }

    /// Asks half a second or more apart are each forced at once.
    func testAsksHalfASecondApartAreEachAtOnce() {
        var limiter = KeyframeLimiter()
        XCTAssertEqual(limiter.ask(now: 1), .now)
        XCTAssertEqual(limiter.ask(now: 1.5), .now)
        XCTAssertEqual(limiter.ask(now: 3), .now)
    }
}
