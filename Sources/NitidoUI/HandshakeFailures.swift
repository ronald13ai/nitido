import Foundation

/// The sharer's count of wrong codes (spec 13): three change the code (`ShareModel.rotateCode`).
///
/// It counts attempts, not failed handshakes. One viewer's attempt can fail the handshake more than once: on two Macs
/// the sharer logged four bad MACs within two seconds for one wrong code (Network.framework trying the handshake again,
/// or on another address) and rotated the code after that single attempt. Failures from one address within `window` seconds of the first are
/// one attempt, up to `perAttempt` of them; the next one starts another, so a guesser trying codes as fast as it can
/// from one address still meets the rotation by its ninth guess. Only a failure on the keys counts (`Link.keyMismatch`):
/// a port scan, a connection cut before the handshake ended or a protocol mismatch says nothing about the code.
struct HandshakeFailures {
    static let window: Double = 3
    static let perAttempt = 4
    static let rotateAfter = 3

    /// Attempts since the code last changed.
    private(set) var count = 0
    /// Per address, the attempt under way: when its first failure came and how many it has had.
    private var attempts: [String: (start: Double, failures: Int)] = [:]

    var shouldRotate: Bool { count >= Self.rotateAfter }

    /// Records one connection that ended before it proved the code, from `host` (nil when it has no address, which then
    /// counts on its own) at `now` in seconds. True when it counts as a new attempt.
    mutating func record(host: String?, keyMismatch: Bool, at now: Double) -> Bool {
        guard keyMismatch else { return false }
        attempts = attempts.filter { now - $0.value.start < Self.window }
        if let host {
            if let attempt = attempts[host], attempt.failures < Self.perAttempt {
                attempts[host] = (attempt.start, attempt.failures + 1)
                return false
            }
            attempts[host] = (now, 1)
        }
        count += 1
        return true
    }

    /// The code changed: counting starts again. An attempt under way stays one, so its last failures, on the old
    /// listener's connections, do not count against the new code.
    mutating func rotated() { count = 0 }
}
