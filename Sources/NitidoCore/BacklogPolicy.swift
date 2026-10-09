import Foundation

/// The sender's dropping rule (spec section 8), as a pure decision: when non-key frames are skipped for the send
/// backlog, and when the keyframe that lets the viewer decode again is asked for. The share hands it every reading of
/// the backlog, each encoded frame's (`delta`, `keyframeSent`) and the 250 ms loop's (`observe`, `keyframeDue`), at the
/// rate the encoder runs at, without the keyframes still being sent (`Link.backlogBytesExcludingKeyframes`); `now` is
/// in seconds.
///
/// The backlog is judged in time and with hysteresis, not by a byte count at one reading. The rule it replaces skipped
/// as soon as one reading was over four frames' worth: on the two-Mac test of 2026-10-09 (2692×1756 HEVC over Wi-Fi 6,
/// a TextEdit window scrolled with the trackpad) 144 kB, about 60 ms of traffic at 20 Mbps, tripped it on one Wi-Fi
/// burst, the backlog drained 17 ms later, and the keyframe sent then refilled it and tripped it again: a slideshow of
/// keyframes, 10 to 48 fps on the viewer for 58 captured. Now:
/// - Deltas are skipped only once the backlog has stayed over `threshold` (150 ms worth, or four frames if that were
///   more) for `persistence`: from the first reading over it to one 100 ms later, with no reading at or under it in
///   between. Over `ceiling` (a second's worth) they are skipped at the first reading.
/// - From then on every delta is skipped until a keyframe has gone out: it would refer to frames the viewer never got.
///   Once the backlog is under one frame's worth, `keyframeDue` asks for that keyframe, once, and again only if none
///   went out within `keyframeRetry`.
/// - For `holdOff` after the keyframe that ends a skip, only the ceiling starts another: the link gets the time to
///   recover with the rate the bitrate controller just cut (`takeTrip`), instead of the keyframe starting the next skip.
public struct BacklogPolicy: Sendable {
    /// Over this many seconds' worth of bytes the backlog starts to count against the link.
    public static let thresholdSeconds = 0.15
    /// Over this many seconds' worth the frames are skipped at once.
    public static let ceilingSeconds = 1.0
    /// How long the backlog stays over the threshold before frames are skipped.
    public static let persistence = 0.1
    /// After the keyframe that ends a skip, how long only the ceiling skips again.
    public static let holdOff = 0.5
    /// A keyframe asked for after the drain and not gone out within this long is asked for again.
    public static let keyframeRetry = 1.0
    /// Readings a few nanoseconds short of a period, from adding up times in seconds, still complete it.
    private static let slack = 1e-6

    public enum Decision: Equatable, Sendable {
        /// The delta goes out.
        case send
        /// The delta is skipped: a skip is on, and no keyframe has gone out since it started.
        case skip
        /// The delta is skipped and the skip starts with it: the backlog had been over the threshold for `overFor`
        /// seconds, or was over the ceiling.
        case trip(overFor: Double)
    }

    /// From a trip until a keyframe has gone out: every delta is skipped.
    public private(set) var skipping = false
    /// Deltas skipped since the skip started.
    public private(set) var skipped = 0
    /// When the skip started; nil while none is on.
    public private(set) var trippedAt: Double?
    /// The first reading over the threshold with none at or under it since; nil while the last reading was not over it.
    private var overSince: Double?
    /// Until then only the ceiling starts a skip.
    private var holdOffUntil = -Double.infinity
    private var keyframeAskedAt: Double?
    /// A skip started since `takeTrip` last said so.
    private var tripped = false

    public init() {}

    /// One frame's worth of bytes at 60 fps: the unit of the drain.
    public static func frameBytes(bitsPerSecond: Int) -> Int { bitsPerSecond / 8 / 60 }

    /// The most the backlog may hold for long: 150 ms worth, or four frames' worth if that were more (it is not at 60
    /// fps; the four frames are the rule this one replaced).
    public static func threshold(bitsPerSecond: Int) -> Int {
        max(4 * frameBytes(bitsPerSecond: bitsPerSecond), Int(Double(bitsPerSecond) / 8 * thresholdSeconds))
    }

    /// A backlog over this skips at once: a second's worth.
    public static func ceiling(bitsPerSecond: Int) -> Int { Int(Double(bitsPerSecond) / 8 * ceilingSeconds) }

    /// A reading with no frame to decide on (the 250 ms loop): it starts or ends the time over the threshold.
    public mutating func observe(backlogBytes: Int, bitsPerSecond: Int, now: Double) {
        guard !skipping else { return }
        if backlogBytes > Self.threshold(bitsPerSecond: bitsPerSecond) {
            if overSince == nil { overSince = now }
        } else {
            overSince = nil
        }
    }

    /// What happens to a delta the encoder just made, with the backlog as it is now.
    public mutating func delta(backlogBytes: Int, bitsPerSecond: Int, now: Double) -> Decision {
        if skipping { skipped += 1; return .skip }
        observe(backlogBytes: backlogBytes, bitsPerSecond: bitsPerSecond, now: now)
        guard let since = overSince else { return .send }
        let overFor = now - since
        let overCeiling = backlogBytes > Self.ceiling(bitsPerSecond: bitsPerSecond)
        let lasted = overFor >= Self.persistence - Self.slack && now >= holdOffUntil - Self.slack
        guard overCeiling || lasted else { return .send }
        skipping = true; skipped = 1; trippedAt = now; tripped = true
        overSince = nil; keyframeAskedAt = nil
        return .trip(overFor: overFor)
    }

    /// A keyframe went out. One that ends a skip starts the hold-off; any other (the encoder's own, one a viewer asked
    /// for) changes nothing.
    public mutating func keyframeSent(now: Double) {
        guard skipping else { return }
        skipping = false; skipped = 0; trippedAt = nil; keyframeAskedAt = nil
        overSince = nil
        holdOffUntil = now + Self.holdOff
    }

    /// True when the keyframe that ends the skip should be asked for now: once the backlog is under one frame's worth,
    /// and again if none went out within `keyframeRetry`.
    public mutating func keyframeDue(backlogBytes: Int, bitsPerSecond: Int, now: Double) -> Bool {
        guard skipping, backlogBytes < Self.frameBytes(bitsPerSecond: bitsPerSecond) else { return false }
        if let asked = keyframeAskedAt, now - asked < Self.keyframeRetry - Self.slack { return false }
        keyframeAskedAt = now
        return true
    }

    /// Whether a skip started since the last call: congestion that lasted, which the bitrate controller cuts for at its
    /// next update, hold or not (`BitrateController.update(skippedForBacklog:)`).
    public mutating func takeTrip() -> Bool {
        defer { tripped = false }
        return tripped
    }
}
