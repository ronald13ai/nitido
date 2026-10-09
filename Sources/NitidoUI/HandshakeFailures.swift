import Foundation

/// The sharer's count of wrong codes (spec 13): three change the code (`ShareModel.rotateCode`).
///
/// It counts attempts, not failed handshakes. One viewer's attempt can fail the handshake more than once: on two Macs
/// the sharer logged four bad MACs within two seconds for one wrong code (most likely Network.framework trying the
/// handshake again, or on another address) and rotated the code after that single attempt. A failure less than `gap`
/// seconds after the last one from the same address joins that address's attempt, up to `perAttempt` of them; a longer
/// gap, or a fifth failure, starts another. Network.framework's own tries came 0.4 to 0.8 s apart, while a person reads
/// the shake, changes a digit of the code still in the field and presses Return a second or more later, so each code
/// typed counts, and a guesser trying codes as fast as it can from one address still meets the rotation by its ninth
/// guess. Only a failure on the keys counts (`Link.keyMismatch`): a port scan, a connection cut before the handshake
/// ended or a protocol mismatch says nothing about the code.
struct HandshakeFailures {
    static let gap: Double = 1
    static let perAttempt = 4
    static let rotateAfter = 3

    /// Attempts since the code last changed.
    private(set) var count = 0
    /// Per address, the attempt under way: when its last failure came and how many it has had.
    private var attempts: [String: (last: Double, failures: Int)] = [:]

    var shouldRotate: Bool { count >= Self.rotateAfter }

    /// Records one connection that ended before it proved the code, from `host` (nil when it has no address, which then
    /// counts on its own) at `now` in seconds. True when it counts as a new attempt.
    mutating func record(host: String?, keyMismatch: Bool, at now: Double) -> Bool {
        guard keyMismatch else { return false }
        attempts = attempts.filter { now - $0.value.last < Self.gap }
        if let host {
            if let attempt = attempts[host], attempt.failures < Self.perAttempt {
                attempts[host] = (now, attempt.failures + 1)
                return false
            }
            attempts[host] = (now, 1)
        }
        count += 1
        return true
    }

    /// The code changed: counting starts again from nothing, the attempts under way included, so the new code also
    /// changes by the ninth guess against it. The sharer lets go of the old listener's handshakes as it changes the code,
    /// so no failure aimed at the old code comes after this.
    mutating func rotated() { count = 0; attempts = [:] }
}
