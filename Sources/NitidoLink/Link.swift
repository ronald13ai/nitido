import Foundation
import Network
import QuartzCore
import Security
import NitidoCore
import os

private let log = Logger(subsystem: "ai.ronar.nitido", category: "link")

/// One encrypted connection. Frames messages, answers pings, measures RTT and clock offset, tracks send backlog.
///
/// Threading: everything that changes the link runs on `queue` (Network.framework callbacks, the ping timer,
/// the connect deadlines, `close()` and `abort()`). The values callers read from other threads (`state`, `peerHello`,
/// `lastRTTMs`, `clockOffsetNs`, `backlogBytes`, `wasReady`, `keyMismatch`) and the ping bookkeeping live behind `lock`.
public final class Link: @unchecked Sendable {
    public enum State: Sendable, Equatable { case connecting, ready, failed(String), cancelled }

    public let role: Role
    public let messages: AsyncStream<Message>
    public let states: AsyncStream<State>
    public var state: State { lock.withLock { _state } }
    public var peerHello: Hello? { lock.withLock { _peerHello } }
    /// The latest pong's RTT, milliseconds (nil until the first pong).
    public var lastRTTMs: Double? { lock.withLock { _lastRTTMs } }
    /// Peer clock minus local clock, nanoseconds, from the pong with the lowest RTT in the last 10 s, so queueing
    /// behind video in one direction does not bias it (`ClockOffsetFilter`; nil until the first pong).
    public var clockOffsetNs: Int64? { lock.withLock { _clockOffsetNs } }
    public var backlogBytes: Int { lock.withLock { backlog } }
    /// True once the link has been ready, even after it ended: it proved the code.
    public var wasReady: Bool { lock.withLock { _wasReady } }
    /// True when the TLS handshake failed because the two sides derived different keys: with the pre-shared key, the
    /// viewer's code is not the one the sharer listens with ("bad MAC"). Set before `states` reports the failure.
    public var keyMismatch: Bool { lock.withLock { _keyMismatch } }
    /// The reason the other side gave in its `bye` (`ByeReason`), once one came. Set before `states` reports `.cancelled`.
    public var byeReason: UInt8? { lock.withLock { _byeReason } }

    private let connection: NWConnection
    private let hello: Hello
    /// Longest a link may stay `.connecting` in total, whatever Network.framework is doing (a handshake that
    /// never answers, a Bonjour name that never resolves).
    private let connectTimeout: Double
    /// Longest a link may stay `.connecting` after Network.framework first reports `.waiting` for a reason
    /// other than TLS (connection refused, host unreachable, Local Network denied).
    private let waitingTimeout: Double
    private let queue = DispatchQueue(label: "ai.ronar.nitido.link", qos: .userInteractive)

    // Behind `lock`.
    private let lock = NSLock()
    private var _state: State = .connecting
    private var _peerHello: Hello?
    private var _lastRTTMs: Double?
    private var _clockOffsetNs: Int64?
    private var offsets = ClockOffsetFilter()
    private var backlog = 0
    private var _wasReady = false
    private var _keyMismatch = false
    private var _byeReason: UInt8?
    private var nextPing: UInt32 = 0
    /// Ping id to the `tNs` it carried, so a pong only counts when it echoes that exact time.
    private var pingSentAt: [UInt32: UInt64] = [:]

    // Only touched on `queue`.
    private var decoder = Wire.Decoder()
    private var pingTimer: DispatchSourceTimer?
    private var waitingDeadlineArmed = false
    /// When the last pong came (`CACurrentMediaTime`); the ping timer fails a link that has heard none for 3 s.
    private var lastPongAt: Double = 0
    /// Test only: stops answering pings, as a peer that froze or lost its network would.
    private var muted = false
    /// Set by `close()`: the stream ending after it is this side's doing, not the other side gone.
    private var closing = false

    private let messageOut: AsyncStream<Message>.Continuation
    private let stateOut: AsyncStream<State>.Continuation

    init(connection: NWConnection, role: Role, hello: Hello, connectTimeout: Double = 15, waitingTimeout: Double = 5) {
        self.connection = connection; self.role = role; self.hello = hello
        self.connectTimeout = connectTimeout; self.waitingTimeout = waitingTimeout
        (messages, messageOut) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (states, stateOut) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(16))
    }

    public static func connect(to endpoint: NWEndpoint, code: String, sharerName: String, hello: Hello) -> Link {
        connect(to: endpoint, code: code, sharerName: sharerName, hello: hello, connectTimeout: 15, waitingTimeout: 5)
    }

    static func connect(to endpoint: NWEndpoint, code: String, sharerName: String, hello: Hello,
                        connectTimeout: Double, waitingTimeout: Double) -> Link {
        let link = Link(connection: NWConnection(to: endpoint, using: LinkTLS.parameters(code: code, sharerName: sharerName)),
                        role: .view, hello: hello, connectTimeout: connectTimeout, waitingTimeout: waitingTimeout)
        link.start()
        return link
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] s in
            guard let self else { return }
            switch s {
            case .ready:
                // A deadline or close() may already have ended this link while `.ready` was queued.
                guard state == .connecting else { return }
                lock.withLock { _wasReady = true }; lastPongAt = CACurrentMediaTime()
                setState(.ready); send(.hello(hello)); receiveLoop(); startPings()
            case .failed(let e):
                log.error("\(self.role.logName, privacy: .public) connection failed: \(e.localizedDescription, privacy: .public)")
                noteKeyMismatch(e)
                finish(.failed(e.localizedDescription))
            case .cancelled: finish(.cancelled)
            case .waiting(let e):
                // A failed TLS handshake (wrong code) parks a client connection in .waiting, where
                // Network.framework would retry the same doomed handshake forever: end it as a failure.
                if case .tls = e {
                    log.error("handshake failed: \(e.localizedDescription, privacy: .public)")
                    noteKeyMismatch(e)
                    finish(.failed(e.localizedDescription)); connection.cancel()
                } else {
                    // Refused, unreachable or Local Network denied: Network.framework retries on its own, which
                    // can last forever (a stale Bonjour peer). Give it `waitingTimeout`, then fail.
                    log.error("waiting: \(e.localizedDescription, privacy: .public)")
                    guard state == .connecting, !waitingDeadlineArmed else { return }
                    waitingDeadlineArmed = true
                    let reason = e.plainDescription
                    queue.asyncAfter(deadline: .now() + waitingTimeout) { [weak self] in
                        self?.giveUpConnecting("Could not reach the other Mac: \(reason)")
                    }
                }
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + connectTimeout) { [weak self, connectTimeout] in
            self?.giveUpConnecting("No answer from the other Mac within \(connectTimeout.formatted()) seconds.")
        }
    }

    public func send(_ m: Message) {
        let data = Wire.encode(m)
        lock.withLock { backlog += data.count }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            lock.withLock { backlog -= data.count }
            if let error { log.error("send: \(error.localizedDescription)") }
        })
    }

    /// Ends the link. A ready link says `bye` with `reason` (`ByeReason`) first and is cancelled once that is sent, or
    /// after one second if the send never completes; a link that never became ready is cancelled at once. Either way
    /// `states` ends with `.cancelled` (or the failure that got there first).
    public func close(reason: UInt8 = ByeReason.ended) { close(reason: reason, whenSent: nil) }

    /// `close`, and returns once the `bye` has been handed to the network (or the one-second fallback cancelled the
    /// connection, or the link was not ready): a process about to quit waits for this, so it does not cut the bye off.
    public func closeAndWait(reason: UInt8 = ByeReason.ended) async {
        await withCheckedContinuation { (sent: CheckedContinuation<Void, Never>) in
            close(reason: reason) { sent.resume() }
        }
    }

    private func close(reason: UInt8, whenSent: (@Sendable () -> Void)?) {
        let connection = connection
        // Taken once: by the send's completion or by the fallback, whichever comes first.
        let pending = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: whenSent)
        let cancel: @Sendable () -> Void = {
            connection.cancel()
            pending.withLock { waiter in defer { waiter = nil }; return waiter }?()
        }
        queue.async { [self] in
            closing = true
            pingTimer?.cancel(); pingTimer = nil
            guard state == .ready else { cancel(); return }
            connection.send(content: Wire.encode(.bye(reason: reason)), completion: .contentProcessed { _ in cancel() })
            queue.asyncAfter(deadline: .now() + 1) { cancel() }
        }
    }

    /// Cancels without sending bye, like a cable pull. Used by tests and when the process dies.
    public func abort() { queue.async { [self] in pingTimer?.cancel(); pingTimer = nil; connection.cancel() } }
    func muteForTesting() { queue.async { [self] in muted = true } }
    /// Test only: counts bytes as waiting to be sent (a negative count takes them back), as a congested network would.
    func addBacklogForTesting(_ bytes: Int) { lock.withLock { backlog += bytes } }

    /// The TLS statuses that mean the other side holds another key (RFC 5489 PSK: the Finished message does not
    /// decrypt). The side that fails to decrypt reports its own status, the other one the peer's alert.
    static let keyMismatchStatuses: Set<OSStatus> = [
        errSSLBadRecordMac, errSSLPeerBadRecordMac, errSSLDecryptionFail, errSSLPeerDecryptionFail, errSSLPeerDecryptError,
    ]

    /// On `queue`, before the failure is reported: remembers a handshake that failed because the keys differ.
    private func noteKeyMismatch(_ e: NWError) {
        guard case .tls(let status) = e, Self.keyMismatchStatuses.contains(status), state == .connecting else { return }
        lock.withLock { _keyMismatch = true }
    }

    /// On `queue`: fails a link that is still connecting; does nothing once it is ready or ended.
    private func giveUpConnecting(_ reason: String) {
        guard state == .connecting else { return }
        log.error("\(self.role.logName, privacy: .public) link gave up connecting: \(reason, privacy: .public)")
        finish(.failed(reason)); connection.cancel()
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do { for m in try decoder.feed(data) { handle(m) } }
                catch {
                    log.error("protocol error from peer: \(String(describing: error), privacy: .public)")
                    finish(.failed("protocol: \(error)")); connection.cancel(); return
                }
            }
            // `bye` ends a link as `.cancelled` (`handle`, possibly in this same delivery), and so does this side's own
            // `close()`; both cancel the connection. What follows either (the end of the stream, a cancelled receive) is
            // that, not a fault, and logs nothing. A stream that ends, or a receive that fails, while the link is still
            // up is the other side gone (a process that died, a connection cut on the way): a failure, which a viewer's
            // `LinkSession` answers by reconnecting.
            let up = state == .ready && !closing
            if let error {
                guard up else { finish(.cancelled); return }
                log.error("receive failed: \(error.localizedDescription, privacy: .public)")
                finish(.failed(error.localizedDescription)); return
            }
            if complete {
                guard up else { finish(.cancelled); return }
                log.error("\(self.role.logName, privacy: .public) link: the other side closed the connection without bye")
                finish(.failed("The other side closed the connection without saying goodbye.")); connection.cancel(); return
            }
            receiveLoop()
        }
    }

    private func handle(_ m: Message) {
        let now = CACurrentMediaTime()
        switch m {
        case .hello(let h):
            lock.withLock { _peerHello = h }
            if h.protocolVersion != protocolVersion {
                log.error("protocol version mismatch: peer speaks \(h.protocolVersion), this side \(protocolVersion)")
                send(.bye(reason: ByeReason.protocolMismatch)); finish(.failed("protocol version \(h.protocolVersion), expected \(protocolVersion)")); connection.cancel(); return
            }
            messageOut.yield(m)
        case .ping(let id, let t):
            guard !muted else { return }
            send(.pong(id: id, originalTNs: t, replyTNs: UInt64(now * 1e9)))
        case .pong(let id, let original, let reply):
            lastPongAt = now
            let sent = lock.withLock { pingSentAt.removeValue(forKey: id) }
            guard let sent else { return }
            guard let sample = Self.pongSample(sentTNs: sent, originalTNs: original, replyTNs: reply, now: now) else {
                log.error("dropped pong \(id): echoed time \(original) or reply time \(reply) out of range")
                return
            }
            lock.withLock {
                _lastRTTMs = sample.rttMs
                offsets.add(rttMs: sample.rttMs, offsetNs: sample.offsetNs, at: now)
                _clockOffsetNs = offsets.offsetNs(now: now)
            }
        case .bye(let reason):
            lock.withLock { _byeReason = reason }
            finish(.cancelled); connection.cancel()
        default:
            messageOut.yield(m)
        }
    }

    /// RTT and clock offset from one pong, or nil when the peer's fields cannot be right: the echoed time must be
    /// the exact `tNs` this side sent for that id, and the reply time must fit an `Int64`. Every field of a pong
    /// comes from the peer, so nothing here may trap on its values.
    static func pongSample(sentTNs: UInt64, originalTNs: UInt64, replyTNs: UInt64, now: Double) -> (rttMs: Double, offsetNs: Int64)? {
        guard originalTNs == sentTNs, let replyNs = Int64(exactly: replyTNs) else { return nil }
        let t0 = Double(originalTNs) / 1e9, t3 = now
        guard t3 >= t0, let midNs = Int64(exactly: (((t0 + t3) / 2) * 1e9).rounded()) else { return nil }
        let (offset, overflow) = replyNs.subtractingReportingOverflow(midNs)
        guard !overflow else { return nil }
        return ((t3 - t0) * 1000, offset)
    }

    private func startPings() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if CACurrentMediaTime() - lastPongAt > 3 {
                log.error("\(self.role.logName, privacy: .public) link heard no pong for 3 seconds; failing it")
                finish(.failed("No response from the other side for 3 seconds")); connection.cancel(); return
            }
            let tNs = UInt64(CACurrentMediaTime() * 1e9)
            let id = lock.withLock { () -> UInt32 in
                nextPing &+= 1; pingSentAt[nextPing] = tNs
                pingSentAt = pingSentAt.filter { tNs &- $0.value < 10_000_000_000 }
                return nextPing
            }
            send(.ping(id: id, tNs: tNs))
        }
        timer.resume()
        pingTimer = timer
    }

    private func setState(_ s: State) { lock.withLock { _state = s }; stateOut.yield(s) }

    /// On `queue`: moves a connecting or ready link to its final state once and ends both streams.
    private func finish(_ s: State) {
        let ended = lock.withLock { () -> Bool in
            guard _state == .ready || _state == .connecting else { return false }
            _state = s
            return true
        }
        guard ended else { return }
        pingTimer?.cancel(); pingTimer = nil
        stateOut.yield(s)
        messageOut.finish(); stateOut.finish()
    }
}

private extension Role {
    var logName: String { self == .share ? "sharer" : "viewer" }
}
