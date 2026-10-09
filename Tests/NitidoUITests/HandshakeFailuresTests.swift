import XCTest
@testable import NitidoUI

/// How the sharer counts wrong codes: per attempt, and only failures on the keys.
final class HandshakeFailuresTests: XCTestCase {
    /// Two Macs, one wrong code: the sharer logged four bad MACs within two seconds and rotated its code after that
    /// single attempt. A failure less than a second after the last one from the same address is the same attempt.
    func testFourBadMACsFromOneHostWithinTwoSecondsAreOneFailure() {
        var failures = HandshakeFailures()
        let counted = [0, 0.4, 1.1, 1.9].map { failures.record(host: "192.168.1.31", keyMismatch: true, at: 100 + $0) }
        XCTAssertEqual(counted, [true, false, false, false])
        XCTAssertEqual(failures.count, 1)
        XCTAssertFalse(failures.shouldRotate)
    }

    /// Network.framework's own tries of one attempt came 0.4 to 0.8 s apart on two Macs. Four failures half a second
    /// apart are one attempt, although the last comes a second and a half after the first.
    func testFourFailuresHalfASecondApartAreOneAttempt() {
        var failures = HandshakeFailures()
        let counted = [0, 0.5, 1.0, 1.5].map { failures.record(host: "192.168.1.31", keyMismatch: true, at: 100 + $0) }
        XCTAssertEqual(counted, [true, false, false, false])
        XCTAssertEqual(failures.count, 1)
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
    }

    /// A wrong code leaves the code typed in the field: a person changes one digit and presses Return a second or two
    /// after the shake. Three attempts typed 1.5 s apart are three wrong codes, and the third rotates the code.
    func testThreeAttemptsTypedOneAndAHalfSecondsApartCountThreeAndRotate() {
        var failures = HandshakeFailures()
        for (i, t) in [0.0, 1.5, 3.0].enumerated() {
            XCTAssertFalse(failures.shouldRotate, "not before the third attempt (\(i + 1))")
            XCTAssertTrue(failures.record(host: "192.168.1.31", keyMismatch: true, at: t), "attempt \(i + 1) counts")
        }
        XCTAssertEqual(failures.count, 3)
        XCTAssertTrue(failures.shouldRotate)
    }

    /// The code changed: counting starts again from nothing, the attempt under way included, so the next code also
    /// changes by the ninth guess against it. (The sharer lets go of the old listener's handshakes when it rotates, so
    /// nothing aimed at the old code is counted against the new one.)
    func testRotationClearsTheAttempts() {
        var failures = HandshakeFailures()
        var t = 0.0
        func guessesUntilRotation() -> Int {
            var guesses = 0
            while !failures.shouldRotate {
                _ = failures.record(host: "192.168.1.66", keyMismatch: true, at: t)
                guesses += 1; t += 0.01
            }
            return guesses
        }
        XCTAssertEqual(guessesUntilRotation(), 9)
        failures.rotated()
        XCTAssertEqual(failures.count, 0)
        XCTAssertEqual(guessesUntilRotation(), 9, "the new code changes by the ninth guess against it too")
        failures.rotated()
        XCTAssertTrue(failures.record(host: "192.168.1.66", keyMismatch: true, at: t), "the first guess after a change counts")
        XCTAssertEqual(failures.count, 1)
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

    /// A guesser trying codes as fast as it can from one address is not one attempt forever: past four failures in one
    /// attempt the next one counts again, so the code still changes by the ninth guess (two attempts of four, then one).
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
