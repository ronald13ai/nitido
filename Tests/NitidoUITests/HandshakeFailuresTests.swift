import XCTest
@testable import NitidoUI

/// How the sharer counts wrong codes: per attempt, and only failures on the keys.
final class HandshakeFailuresTests: XCTestCase {
    /// Two Macs, one wrong code: the sharer logged four bad MACs within two seconds and rotated its code after that
    /// single attempt. Failures from one address within three seconds are one attempt.
    func testFourBadMACsFromOneHostWithinTwoSecondsAreOneFailure() {
        var failures = HandshakeFailures()
        let counted = [0, 0.4, 1.1, 1.9].map { failures.record(host: "192.168.1.31", keyMismatch: true, at: 100 + $0) }
        XCTAssertEqual(counted, [true, false, false, false])
        XCTAssertEqual(failures.count, 1)
        XCTAssertFalse(failures.shouldRotate)
    }

    /// Three attempts, each a few seconds after the last (a person reading the shake and typing again), rotate the code.
    func testThreeDistinctAttemptsRotate() {
        var failures = HandshakeFailures()
        for (i, t) in [0.0, 3.2, 7.5].enumerated() {
            XCTAssertFalse(failures.shouldRotate, "not before the third attempt (\(i + 1))")
            // Each attempt may fail more than once on the sharer; its repeats do not count.
            XCTAssertTrue(failures.record(host: "192.168.1.31", keyMismatch: true, at: t))
            XCTAssertFalse(failures.record(host: "192.168.1.31", keyMismatch: true, at: t + 0.2))
        }
        XCTAssertEqual(failures.count, 3)
        XCTAssertTrue(failures.shouldRotate)
        failures.rotated()
        XCTAssertEqual(failures.count, 0)
        XCTAssertFalse(failures.record(host: "192.168.1.31", keyMismatch: true, at: 7.9), "the attempt under way when the code changed")
        XCTAssertEqual(failures.count, 0)
    }

    /// A connection refused, a port scan that closes before the handshake ends, a protocol version mismatch: none of
    /// them says anything about the code, so none counts, however many come.
    func testAFailureThatIsNotOnTheKeysNeverCounts() {
        var failures = HandshakeFailures()
        for i in 0..<20 { XCTAssertFalse(failures.record(host: "10.0.0.\(i % 3)", keyMismatch: false, at: Double(i) * 4)) }
        XCTAssertEqual(failures.count, 0)
        XCTAssertFalse(failures.shouldRotate)
    }

    /// Another address is another attempt, at the same moment or not.
    func testFailuresFromTwoHostsCountApart() {
        var failures = HandshakeFailures()
        XCTAssertTrue(failures.record(host: "192.168.1.31", keyMismatch: true, at: 0))
        XCTAssertTrue(failures.record(host: "192.168.1.32", keyMismatch: true, at: 0.1))
        XCTAssertEqual(failures.count, 2)
    }

    /// A guesser trying codes as fast as it can from one address is not one attempt forever: past four failures in the
    /// window the next one counts again, so the code still changes by the ninth guess (two attempts of four, then one).
    func testAGuesserFromOneAddressStillMeetsTheRotation() {
        var failures = HandshakeFailures()
        var guesses = 0
        while !failures.shouldRotate {
            _ = failures.record(host: "192.168.1.66", keyMismatch: true, at: Double(guesses) * 0.01)
            guesses += 1
        }
        XCTAssertEqual(guesses, 9, "four per attempt, the third attempt's first guess rotates")
    }

    /// A connection with no address to count it by counts on its own.
    func testAFailureWithoutAnAddressCountsOnItsOwn() {
        var failures = HandshakeFailures()
        XCTAssertTrue(failures.record(host: nil, keyMismatch: true, at: 0))
        XCTAssertTrue(failures.record(host: nil, keyMismatch: true, at: 0.1))
        XCTAssertEqual(failures.count, 2)
    }
}
