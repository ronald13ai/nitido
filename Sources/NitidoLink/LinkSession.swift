import Foundation
import Network
import NitidoCore
import os

private let log = Logger(subsystem: "ai.ronar.nitido", category: "session")

/// A viewer-side connection that survives drops: reconnects with backoff (0.5, 1, 2, 5 s) while open.
/// A failure before the first ready state ends the session: as `.codeRejected` when the handshake failed because the
/// sharer holds another key (the code typed is wrong), as `.closed` with the reason otherwise (refused, unreachable,
/// Local Network denied, no answer), so a right code is never called wrong. A reconnect the sharer turns away with
/// another key ends it too: its code changed (a new one every launch, or after three failed handshakes).
public final class LinkSession: @unchecked Sendable {
    public enum State: Sendable, Equatable {
        case connecting(attempt: Int)
        case ready
        case reconnecting(attempt: Int, delay: Double)
        /// The first handshake failed because the two sides derived different keys: the sharer listens with another
        /// code than the one typed. Final, like `.closed`: `states` ends after it.
        case codeRejected
        case closed(String?)
    }

    public let messages: AsyncStream<Message>
    public let states: AsyncStream<State>
    public var lastRTTMs: Double? { current?.lastRTTMs }
    public var clockOffsetNs: Int64? { current?.clockOffsetNs }
    public var backlogBytes: Int { current?.backlogBytes ?? 0 }

    private let endpoint: NWEndpoint, code: String, sharerName: String, hello: Hello
    /// Handed to every `Link` this session makes (`Link.connect`); only tests shorten them.
    private let connectTimeout: Double, waitingTimeout: Double
    private let lock = NSLock()
    private var _current: Link?
    private var current: Link? { lock.lock(); defer { lock.unlock() }; return _current }
    private var open = true
    private var attempt = 0
    private var everReady = false
    private let messageOut: AsyncStream<Message>.Continuation
    private let stateOut: AsyncStream<State>.Continuation

    public convenience init(endpoint: NWEndpoint, code: String, sharerName: String, hello: Hello) {
        self.init(endpoint: endpoint, code: code, sharerName: sharerName, hello: hello, connectTimeout: 15, waitingTimeout: 5)
    }

    init(endpoint: NWEndpoint, code: String, sharerName: String, hello: Hello, connectTimeout: Double, waitingTimeout: Double) {
        self.endpoint = endpoint; self.code = code; self.sharerName = sharerName; self.hello = hello
        self.connectTimeout = connectTimeout; self.waitingTimeout = waitingTimeout
        (messages, messageOut) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (states, stateOut) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(16))
    }

    public func start() { attemptConnection() }
    public func send(_ m: Message) { current?.send(m) }

    public func close() { shut()?.close() }

    /// `close`, and returns once the sharer has been told `bye` (`Link.closeAndWait`): a quit waits for this.
    public func closeAndWait() async { await shut()?.closeAndWait() }

    /// Ends the session's streams and hands back the link to close.
    private func shut() -> Link? {
        lock.lock(); open = false; let link = _current; lock.unlock()
        stateOut.yield(.closed(nil)); stateOut.finish(); messageOut.finish()
        return link
    }

    private func attemptConnection() {
        lock.lock()
        guard open else { lock.unlock(); return }
        attempt += 1
        let n = attempt
        let link = Link.connect(to: endpoint, code: code, sharerName: sharerName, hello: hello,
                                connectTimeout: connectTimeout, waitingTimeout: waitingTimeout)
        _current = link
        lock.unlock()
        stateOut.yield(.connecting(attempt: n))
        Task { [weak self] in
            guard let self else { return }
            for await m in link.messages { messageOut.yield(m) }
        }
        Task { [weak self] in
            guard let self else { return }
            for await s in link.states {
                switch s {
                case .ready:
                    lock.withLock { everReady = true; attempt = 0 }
                    stateOut.yield(.ready)
                case .failed(let reason):
                    scheduleRetry(after: reason, codeRejected: link.keyMismatch)
                case .cancelled:
                    // A `bye`. With `sharingStopped` the sharer stopped capturing and listening (a failure, or Stop
                    // Sharing in the menu bar) while its app stays open: say so, since no retry could pair.
                    let stillOpen = lock.withLock { open }
                    guard stillOpen else { break }
                    if link.byeReason == ByeReason.sharingStopped {
                        log.info("\(self.sharerName, privacy: .public) stopped sharing")
                        end(.closed("\(sharerName) stopped sharing."))
                    } else {
                        end(.closed("The sharer ended the session."))
                    }
                case .connecting: break
                }
            }
        }
    }

    private func scheduleRetry(after reason: String, codeRejected: Bool) {
        // `attempt` counts the attempts since the last ready one (0 right after a drop); `n` is the one this retry makes.
        lock.lock(); let stillOpen = open, ready = everReady, n = attempt + 1; lock.unlock()
        guard stillOpen else { return }
        // The first attempt never proved the code. Only a handshake that failed on the keys says the code is wrong;
        // anything else (a Mac that stopped sharing, refused, unreachable, Local Network denied, no answer) is said
        // as it is, so nobody retypes a right code against a Mac that cannot be reached.
        guard ready else {
            if codeRejected {
                log.error("the sharer turned the code away (\(reason, privacy: .public))")
                end(.codeRejected)
            } else {
                log.error("could not connect to \(self.sharerName, privacy: .public): \(reason, privacy: .public)")
                end(.closed("Could not connect to \(sharerName). \(reason)"))
            }
            return
        }
        // The sharer answered, but with a key this code does not make: it was relaunched (a new code every launch) or
        // rotated its code. No retry can pass, and each one would count there as a failed handshake, three of which
        // rotate its code again under whoever is typing it: end the session and ask for the code it shows now.
        guard !codeRejected else {
            log.error("reconnect refused: the sharer no longer takes this code (\(reason, privacy: .public))")
            end(.closed("The code on \(sharerName) has changed. Enter the new code to connect again."))
            return
        }
        let delay = min(5, 0.5 * pow(2, Double(max(0, n - 1))))
        log.info("link failed (\(reason)); retry \(n) in \(delay)s")
        stateOut.yield(.reconnecting(attempt: n, delay: delay))
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
            self?.attemptConnection()
        }
    }

    /// Ends the session on its final state (`.codeRejected` or `.closed`).
    private func end(_ final: State) {
        lock.lock(); open = false; lock.unlock()
        stateOut.yield(final); stateOut.finish(); messageOut.finish()
    }
}
