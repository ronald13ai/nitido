import Foundation

/// When the frames VideoToolbox drops are logged: the first at once, then at most one line a second, which says how
/// many were dropped since the last. A realtime encoder under load lets frames go (the evening two-Mac test of
/// 2026-10-09 logged ten in a row as errors); that is a drop the strip counts, not a failure, and one line a second
/// says it. Times are in seconds. Guarded by the encoder's lock.
struct DropLog {
    /// The shortest time between two lines.
    static let interval = 1.0
    private var unlogged = 0
    private var loggedAt = -Double.infinity

    /// A frame was dropped at `now`: how many drops to log now, this one and those held since the last line, or nil
    /// while the last line is under `interval` old.
    mutating func dropped(now: Double) -> Int? {
        unlogged += 1
        guard now - loggedAt >= Self.interval else { return nil }
        defer { unlogged = 0; loggedAt = now }
        return unlogged
    }
}
