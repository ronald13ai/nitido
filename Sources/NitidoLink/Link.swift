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
/// `lastRTTMs`, `clockOffsetNs`, `backlogBytes`, `wasReady`, `keyMismatch`, `incompatible`, `unreachable`), the ping
/// bookkeeping and `closing`, which `close()` sets before it returns, live behind `lock`.
///
/// `.ready` means the two sides can talk: the TLS handshake proved the code, and the other side's `hello` speaks this
/// side's protocol version. Both sides send their `hello` the moment TLS is up, so this costs one trip across the network.
/// A `hello` with another version fails the link (`incompatible`) after `bye(protocolMismatch)`, and it never becomes
/// ready, so a sharer never hands its viewer's seat to a Mac it cannot talk to (spec 12).
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
    /// Bytes handed to the connection whose send has not completed yet.
    public var backlogBytes: Int { lock.withLock { backlog } }
    /// The backlog without the keyframe on its way: what the sharer's dropping rule, its ceiling and the bitrate
    /// controller judge (spec section 8). A keyframe is one burst the encoder makes on purpose, so its own bytes are
    /// never taken for congestion while it is being sent. Only the oldest keyframe still in flight is left out: the
    /// keyframes queued behind it (a viewer asking for one after another) and the frames behind those count, so a
    /// stream of keyframes is a backlog like any other. Read under one lock, so it is never below zero.
    public var backlogBytesExcludingKeyframes: Int { lock.withLock { backlog - (keyframesInFlight.first ?? 0) } }
    /// True once the TLS handshake has completed, even after the link ended: it proved the code, whether or not the
    /// hellos then matched (`incompatible`).
    public var wasReady: Bool { lock.withLock { _wasReady } }
    /// True when the TLS handshake failed because the two sides derived different keys: with the pre-shared key, the
    /// viewer's code is not the one the sharer listens with ("bad MAC"). Set before `states` reports the failure.
    public var keyMismatch: Bool { lock.withLock { _keyMismatch } }
    /// True when the other side speaks another protocol version: its `hello` said so (`peerHello` has its version), or
    /// its `bye` did (`ByeReason.protocolMismatch`). Set before `states` reports the end.
    public var incompatible: Bool { lock.withLock { _incompatible } }
    /// The reason the other side gave in its `bye` (`ByeReason`), once one came. Set before `states` reports `.cancelled`.
    public var byeReason: UInt8? { lock.withLock { _byeReason } }
    /// True when a link made with `unreachableAfter` failed because its address does not reach the sharer: refused, no
    /// route, or no answer at all in that time (`noPathErrors`). A viewer's session then tries its next route
    /// (`LinkSession`); a connection the address took and then cut is not that. Set before `states` reports the failure.
    public var unreachable: Bool { lock.withLock { _unreachable } }
    /// True when an `unreachable` link failed because its address refused the connection: the host is there and nothing
    /// listens on that port. On a reconnect that means the sharer's listener has moved or is gone (`LinkSession`); a
    /// timeout or no route says something else (an address that changed). Set before `states` reports the failure.
    public var refused: Bool { lock.withLock { _refused } }
    /// The other side's address, without its port or an interface: on the sharer, where a connection came from, which is
    /// what failed handshakes are counted by. Nil when the endpoint is not an address.
    public var remoteHost: String? {
        guard case .hostPort(let host, _) = connection.endpoint else { return nil }
        let text: String
        switch host {
        case .ipv4(let address): text = "\(address)"
        case .ipv6(let address): text = "\(address)"
        case .name(let name, _): text = name
        @unknown default: text = "\(host)"
        }
        return String(text.prefix { $0 != "%" })
    }

    /// Longest one attempt to reach the sharer may take, over every route a viewer tries (`LinkSession`), and longest a
    /// connection the sharer took may take to prove the code.
    public static let defaultConnectTimeout: Double = 8

    private let connection: NWConnection
    private let hello: Hello
    /// Longest a link may stay `.connecting` in total, whatever Network.framework is doing (a handshake that
    /// never answers, a Bonjour name that never resolves).
    private let connectTimeout: Double
    /// Longest a link may stay `.connecting` after Network.framework first reports `.waiting` for a reason
    /// other than TLS (connection refused, host unreachable, Local Network denied).
    private let waitingTimeout: Double
    /// When `connectTimeout` runs out (`CACurrentMediaTime`): a viewer's session hands each route what is left of its
    /// attempt (`LinkSession`), and a wait is never given longer than that.
    private let connectDeadline: Double
    /// A viewer's link to an address the sharer published: a failure that says there is no path (`noPathErrors`:
    /// refused, no route) or no answer within this many seconds fails it at once as `unreachable`, so the session goes
    /// on to its next route. Nil on the last route and on the sharer, where a wait gets `waitingTimeout`.
    private let unreachableAfter: Double?
    private let queue = DispatchQueue(label: "ai.ronar.nitido.link", qos: .userInteractive)

    // Behind `lock`.
    private let lock = NSLock()
    private var _state: State = .connecting
    private var _peerHello: Hello?
    private var _lastRTTMs: Double?
    private var _clockOffsetNs: Int64?
    private var offsets = ClockOffsetFilter()
    private var backlog = 0
    /// The sizes of the keyframes (`.videoFrame` with `isKey`) in `backlog`, oldest first: sends on one connection
    /// complete in the order they were made, so the first is the one on its way.
    private var keyframesInFlight: [Int] = []
    private var _wasReady = false
    private var _keyMismatch = false
    private var _incompatible = false
    private var _byeReason: UInt8?
    private var _unreachable = false
    private var _refused = false
    private var nextPing: UInt32 = 0
    /// Ping id to the `tNs` it carried, so a pong only counts when it echoes that exact time.
    private var pingSentAt: [UInt32: UInt64] = [:]
    /// Set by `close()` before it returns: the link takes no more messages, and the stream ending after it is this
    /// side's doing, not the other side gone.
    private var closing = false

    // Only touched on `queue`.
    private var decoder = Wire.Decoder()
    private var pingTimer: DispatchSourceTimer?
    private var waitingDeadlineArmed = false
    /// When the last pong came (`CACurrentMediaTime`); the ping timer fails a link that has heard none for 3 s.
    private var lastPongAt: Double = 0
    /// Test only: stops answering pings, as a peer that froze or lost its network would.
    private var muted = false

    private let messageOut: AsyncStream<Message>.Continuation
    private let stateOut: AsyncStream<State>.Continuation

    /// `timeLeft` is how much of `connectTimeout` this link has (all of it unless a viewer's session already spent some on
    /// another route); the message on running out names `connectTimeout`, the attempt's whole deadline.
    init(connection: NWConnection, role: Role, hello: Hello, connectTimeout: Double = Link.defaultConnectTimeout,
         waitingTimeout: Double = 5, timeLeft: Double? = nil, unreachableAfter: Double? = nil) {
        self.connection = connection; self.role = role; self.hello = hello
        self.connectTimeout = connectTimeout; self.waitingTimeout = waitingTimeout
        connectDeadline = CACurrentMediaTime() + (timeLeft ?? connectTimeout)
        self.unreachableAfter = unreachableAfter
        (messages, messageOut) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (states, stateOut) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(16))
    }

    public static func connect(to endpoint: NWEndpoint, code: String, sharerName: String, hello: Hello) -> Link {
        connect(to: endpoint, code: code, sharerName: sharerName, hello: hello, connectTimeout: defaultConnectTimeout, waitingTimeout: 5)
    }

    /// `peerToPeer` false keeps the connection off AWDL: an address the sharer published is reached on the network it
    /// is on (`LinkSession`).
    static func connect(to endpoint: NWEndpoint, code: String, sharerName: String, hello: Hello,
                        connectTimeout: Double, waitingTimeout: Double, timeLeft: Double? = nil,
                        unreachableAfter: Double? = nil, peerToPeer: Bool = true) -> Link {
        let parameters = LinkTLS.parameters(code: code, sharerName: sharerName)
        parameters.includePeerToPeer = peerToPeer
        let link = Link(connection: NWConnection(to: endpoint, using: parameters), role: .view, hello: hello,
                        connectTimeout: connectTimeout, waitingTimeout: waitingTimeout, timeLeft: timeLeft,
                        unreachableAfter: unreachableAfter)
        link.start()
        return link
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] s in
            guard let self else { return }
            // What Network.framework does on the way: the record a two-Mac session needs (`log stream --debug`).
            log.debug("\(self.role.logName, privacy: .public) connection with \(String(describing: self.connection.endpoint), privacy: .public): \(String(describing: s), privacy: .public)")
            switch s {
            case .ready:
                // A deadline or close() may already have ended this link while `.ready` was queued. TLS is up: the code
                // is proved. The link is ready once the other side's hello speaks this side's version (`handle`).
                guard state == .connecting else { return }
                lock.withLock { _wasReady = true }
                transmit(.hello(hello)); receiveLoop()
            case .failed(let e):
                log.error("\(self.role.logName, privacy: .public) connection failed: \(e.localizedDescription, privacy: .public)")
                noteKeyMismatch(e)
                noteUnreachable(e)
                // Network.framework expects a failed connection to be cancelled; until then it holds on to it.
                finish(.failed(e.localizedDescription)); connection.cancel()
            case .cancelled: finish(.cancelled)
            case .waiting(let e):
                // A failed TLS handshake (wrong code) parks a client connection in .waiting, where
                // Network.framework would retry the same doomed handshake forever: end it as a failure.
                if case .tls = e {
                    log.error("handshake failed: \(e.localizedDescription, privacy: .public)")
                    noteKeyMismatch(e)
                    finish(.failed(e.localizedDescription)); connection.cancel()
                } else if unreachableAfter != nil, case .posix = e {
                    if Self.hasNoPath(e) {
                        // An address the sharer published that does not take the connection (refused, no route): the
                        // session has another route, so this one ends now rather than after `waitingTimeout`.
                        giveUpUnreachable("Could not reach \(connection.endpoint): \(e.plainDescription)", refused: e == .posix(.ECONNREFUSED))
                    } else {
                        // The address took the connection and cut it (a reset, an abort): the sharer was reached and
                        // may have failed a handshake on the keys already, so another route would make a second one
                        // there, another wrong code for one typed. The attempt ends with the reason, now, rather than
                        // after Network.framework tried this address again.
                        log.error("waiting: \(e.localizedDescription, privacy: .public)")
                        giveUpConnecting("Could not reach the other Mac: \(e.plainDescription)")
                    }
                } else {
                    // Refused, unreachable or Local Network denied: Network.framework retries on its own, which
                    // can last forever (a stale Bonjour peer). Give it `waitingTimeout`, or what is left of the connect
                    // deadline if that is sooner, so the reason is said rather than "No answer", then fail.
                    log.error("waiting: \(e.localizedDescription, privacy: .public)")
                    guard state == .connecting, !waitingDeadlineArmed else { return }
                    waitingDeadlineArmed = true
                    let reason = e.plainDescription
                    let wait = max(0, min(waitingTimeout, connectDeadline - CACurrentMediaTime() - 0.05))
                    queue.asyncAfter(deadline: .now() + wait) { [weak self] in
                        self?.giveUpConnecting("Could not reach the other Mac: \(reason)")
                    }
                }
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + max(0, connectDeadline - CACurrentMediaTime())) { [weak self, connectTimeout] in
            self?.giveUpConnecting("No answer from the other Mac within \(connectTimeout.formatted()) seconds.")
        }
        if let unreachableAfter {
            // No answer at all from a published address: a stale one, or a host that drops the packets.
            queue.asyncAfter(deadline: .now() + unreachableAfter) { [weak self] in
                guard let self else { return }
                giveUpUnreachable("No answer from \(connection.endpoint) within \(unreachableAfter.formatted()) seconds.")
            }
        }
    }

    /// Sends `m` while the link is up: ready, and not being closed by this side. A link that is still connecting, or
    /// is closing or ended before the caller heard, drops it: a viewer's `LinkSession` reconnects, and the other side
    /// asks then for what it needs (a keyframe). `backlogBytes` counts a message until its send completes, and
    /// `backlogBytesExcludingKeyframes` leaves the oldest keyframe out of it for that time.
    public func send(_ m: Message) {
        guard isUp else { log.debug("not sent (type \(m.typeCode)): the link is not up"); return }
        transmit(m)
    }

    /// Hands `m` to the connection, counted in the backlog until its send completes. `send` once the link is up; the
    /// `hello` directly, once TLS is up and before the link is ready.
    private func transmit(_ m: Message) {
        let data = Wire.encode(m)
        let keyframe = if case .videoFrame(let f) = m { f.isKey } else { false }
        lock.withLock { backlog += data.count; if keyframe { keyframesInFlight.append(data.count) } }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            lock.withLock { backlog -= data.count; if keyframe { keyframeSent(data.count) } }
            guard let error else { return }
            // Cut short by the link ending (a bye, `close()`, a failure logged already): no failure of its own.
            if isConnected { log.error("send: \(error.localizedDescription, privacy: .public)") }
            else { log.debug("a send ended with the link: \(error.localizedDescription, privacy: .public)") }
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
        lock.withLock { closing = true }
        let connection = connection
        // Taken once: by the send's completion or by the fallback, whichever comes first.
        let pending = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: whenSent)
        let cancel: @Sendable () -> Void = {
            connection.cancel()
            pending.withLock { waiter in defer { waiter = nil }; return waiter }?()
        }
        queue.async { [self] in
            pingTimer?.cancel(); pingTimer = nil
            guard state == .ready else { cancel(); return }
            connection.send(content: Wire.encode(.bye(reason: reason)), completion: .contentProcessed { _ in cancel() })
            queue.asyncAfter(deadline: .now() + 1) { cancel() }
        }
    }

    /// Cancels without sending bye, like a cable pull. Used by tests and when the process dies.
    public func abort() { queue.async { [self] in pingTimer?.cancel(); pingTimer = nil; connection.cancel() } }
    func muteForTesting() { queue.async { [self] in muted = true } }
    /// Test only: what Network.framework says the connection is doing.
    var connectionStateForTesting: NWConnection.State { connection.state }
    /// Test only: counts bytes as waiting to be sent (a negative count takes them back), as a congested network would;
    /// with `keyframe`, as one keyframe's bytes, queued behind the keyframes held already (a negative count sends the
    /// oldest one of that size, as a completed send would).
    func addBacklogForTesting(_ bytes: Int, keyframe: Bool = false) {
        lock.withLock {
            backlog += bytes
            guard keyframe else { return }
            if bytes > 0 { keyframesInFlight.append(bytes) } else { keyframeSent(-bytes) }
        }
    }
    /// Test only: `backlogBytes` and `backlogBytesExcludingKeyframes` read under one lock: no send completes between.
    var backlogFiguresForTesting: (total: Int, excludingKeyframes: Int) {
        lock.withLock { (backlog, backlog - (keyframesInFlight.first ?? 0)) }
    }

    /// Under `lock`: a keyframe of `size` bytes has been sent. Completions come in send order, so it is the first of
    /// that size; were one ever to come early, the size still takes the right one out.
    private func keyframeSent(_ size: Int) {
        if let index = keyframesInFlight.firstIndex(of: size) { keyframesInFlight.remove(at: index) }
    }

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

    /// The POSIX errors that say an address has no path to the sharer: nothing listens there, no route to it, its network
    /// or host is down, the address is not one this Mac can use, or nothing answered. Any other (a reset, an abort, a
    /// broken pipe) means a host took the connection, and the sharer may have failed a handshake on the keys already.
    static let noPathErrors: Set<POSIXErrorCode> = [
        .ECONNREFUSED, .EHOSTUNREACH, .ENETUNREACH, .ENETDOWN, .EHOSTDOWN, .EADDRNOTAVAIL, .ETIMEDOUT,
    ]

    static func hasNoPath(_ e: NWError) -> Bool {
        guard case .posix(let code) = e else { return false }
        return noPathErrors.contains(code)
    }

    /// On `queue`, before the failure is reported: remembers that a published address has no path to the sharer.
    private func noteUnreachable(_ e: NWError) {
        guard unreachableAfter != nil, Self.hasNoPath(e), state == .connecting else { return }
        lock.withLock { _unreachable = true; _refused = e == .posix(.ECONNREFUSED) }
    }

    /// On `queue`: fails a link to a published address that is still connecting as `unreachable` (and `refused`, when
    /// the address refused the connection).
    private func giveUpUnreachable(_ reason: String, refused: Bool = false) {
        guard state == .connecting else { return }
        log.error("\(self.role.logName, privacy: .public) link: \(reason, privacy: .public)")
        lock.withLock { _unreachable = true; _refused = refused }
        finish(.failed(reason)); connection.cancel()
    }

    /// Test only: whether the connection may use AWDL.
    var includesPeerToPeerForTesting: Bool { connection.parameters.includePeerToPeer }

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
            // up (ready, or waiting for the other side's hello) is the other side gone (a process that died, a connection
            // cut on the way): a failure, which a viewer's `LinkSession` answers by reconnecting.
            let up = isConnected
            if let error {
                guard up else { finish(.cancelled); return }
                log.error("receive failed: \(error.localizedDescription, privacy: .public)")
                finish(.failed(error.localizedDescription)); connection.cancel(); return
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
            // The version this side speaks is the one its own hello carries (`protocolVersion` in the app).
            guard h.protocolVersion == hello.protocolVersion else {
                log.error("\(self.role.logName, privacy: .public) link: protocol version mismatch: the other side speaks \(h.protocolVersion, privacy: .public), this side \(self.hello.protocolVersion, privacy: .public)")
                lock.withLock { _incompatible = true }
                // `bye(1)` first; the connection is cancelled once it is sent, or after a second, as `close` does.
                let connection = connection
                connection.send(content: Wire.encode(.bye(reason: ByeReason.protocolMismatch)),
                                completion: .contentProcessed { _ in connection.cancel() })
                queue.asyncAfter(deadline: .now() + 1) { connection.cancel() }
                finish(.failed("The other Mac speaks protocol \(h.protocolVersion); this one speaks \(hello.protocolVersion)."))
                return
            }
            if state == .connecting {
                // The first hello, in this side's version: the two sides can talk.
                lastPongAt = now
                setState(.ready); startPings()
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
            lock.withLock { _byeReason = reason; if reason == ByeReason.protocolMismatch { _incompatible = true } }
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

    /// Ready, and not being closed by this side.
    private var isUp: Bool { lock.withLock { _state == .ready && !closing } }

    /// TLS is up (the link is ready, or waits for the other side's hello), and this side is not closing it.
    private var isConnected: Bool { lock.withLock { (_state == .ready || _state == .connecting && _wasReady) && !closing } }

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
