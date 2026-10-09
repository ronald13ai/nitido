import Foundation
import Network
import QuartzCore
import NitidoCore
import os

private let log = Logger(subsystem: "ai.ronar.nitido", category: "session")

/// A viewer-side connection that survives drops: reconnects with backoff (0.5, 1, 2 and 4 s, then every 5 s) while
/// open. A failure before the first ready state ends the session: as `.codeRejected` when the handshake failed because
/// the sharer holds another key (the code typed is wrong), as `.closed` with the reason otherwise (refused,
/// unreachable, Local Network denied, no answer), so a right code is never called wrong. A reconnect the sharer turns
/// away with another key ends it too: its code changed (a new one every launch, or after three wrong codes).
///
/// Every attempt goes through the peer's routes in order (`Peer.routes`): an address the sharer published, the next
/// one, then the Bonjour service, all within `Link.defaultConnectTimeout` (8 s). A published address that does not
/// reach the sharer (refused, no route, no answer within `unreachableAfter`: `Link.noPathErrors`) hands over to the next
/// route at once; anything else it says (a failed handshake above all, or a connection it took and reset) is the
/// attempt's answer.
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

    /// Where the sharer may be reached, in the order they are tried; the last one is the Bonjour service (`Peer.routes`).
    private let routes: [NWEndpoint]
    private let code: String, sharerName: String, hello: Hello
    /// Handed to every `Link` this session makes (`Link.connect`); only tests shorten them.
    private let connectTimeout: Double, waitingTimeout: Double, unreachableAfter: Double
    /// Test only: what the current link's connection may use.
    var includesPeerToPeerForTesting: Bool? { current?.includesPeerToPeerForTesting }
    private let lock = NSLock()
    private var _current: Link?
    private var current: Link? { lock.lock(); defer { lock.unlock() }; return _current }
    private var open = true
    private var attempt = 0
    private var everReady = false
    private let messageOut: AsyncStream<Message>.Continuation
    private let stateOut: AsyncStream<State>.Continuation

    /// The longest a published address may go without answering before the next route is tried.
    static let unreachableAfter: Double = 4

    /// To the sharer on `peer`, under the name it keyed its listener with (`Peer.keyName`), through its routes.
    public convenience init(peer: Peer, code: String, hello: Hello) {
        self.init(peer: peer, code: code, hello: hello, connectTimeout: Link.defaultConnectTimeout, waitingTimeout: 5,
                  unreachableAfter: Self.unreachableAfter)
    }

    /// To `endpoint` alone.
    public convenience init(endpoint: NWEndpoint, code: String, sharerName: String, hello: Hello) {
        self.init(endpoint: endpoint, code: code, sharerName: sharerName, hello: hello,
                  connectTimeout: Link.defaultConnectTimeout, waitingTimeout: 5)
    }

    convenience init(peer: Peer, code: String, hello: Hello, connectTimeout: Double, waitingTimeout: Double, unreachableAfter: Double) {
        self.init(routes: peer.routes, code: code, sharerName: peer.keyName, hello: hello, connectTimeout: connectTimeout,
                  waitingTimeout: waitingTimeout, unreachableAfter: unreachableAfter)
    }

    convenience init(endpoint: NWEndpoint, code: String, sharerName: String, hello: Hello, connectTimeout: Double, waitingTimeout: Double) {
        self.init(routes: [endpoint], code: code, sharerName: sharerName, hello: hello, connectTimeout: connectTimeout,
                  waitingTimeout: waitingTimeout, unreachableAfter: Self.unreachableAfter)
    }

    init(routes: [NWEndpoint], code: String, sharerName: String, hello: Hello, connectTimeout: Double, waitingTimeout: Double,
         unreachableAfter: Double) {
        precondition(!routes.isEmpty, "a session needs a route")
        self.routes = routes; self.code = code; self.sharerName = sharerName; self.hello = hello
        self.connectTimeout = connectTimeout; self.waitingTimeout = waitingTimeout; self.unreachableAfter = unreachableAfter
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
        let deadline = CACurrentMediaTime() + connectTimeout
        let link = makeLink(route: 0, deadline: deadline)
        _current = link
        lock.unlock()
        stateOut.yield(.connecting(attempt: n))
        follow(link, route: 0, deadline: deadline)
    }

    /// Under `lock`: the link for `routes[index]`, with what is left of the attempt's `deadline`. A route before the last
    /// is an address the sharer published: it fails fast as `unreachable` when it does not take the connection, and gets
    /// at most `unreachableAfter` seconds, fewer if more would leave the Bonjour service, the last route, under a quarter
    /// of the deadline (2 of the 8 s). The connection stays off AWDL there; the Bonjour service keeps it, as the browser
    /// does, since a sharer found only over AWDL is reached only that way.
    private func makeLink(route index: Int, deadline: Double) -> Link {
        let left = max(0, deadline - CACurrentMediaTime())
        let last = index == routes.count - 1
        let limit = last ? nil : max(0.25, min(unreachableAfter, left - connectTimeout / 4))
        log.info("trying \(String(describing: self.routes[index]), privacy: .public) (route \(index + 1) of \(self.routes.count))")
        return Link.connect(to: routes[index], code: code, sharerName: sharerName, hello: hello,
                            connectTimeout: connectTimeout, waitingTimeout: waitingTimeout, timeLeft: left,
                            unreachableAfter: limit, peerToPeer: last)
    }

    /// Forwards `link`'s messages and answers its states; a route that did not reach the sharer hands over to the next.
    private func follow(_ link: Link, route index: Int, deadline: Double) {
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
                    if link.unreachable, index + 1 < routes.count, let next = nextRoute(after: index, deadline: deadline) {
                        log.info("\(String(describing: self.routes[index]), privacy: .public) did not reach \(self.sharerName, privacy: .public) (\(reason, privacy: .public)); trying the next route")
                        follow(next, route: index + 1, deadline: deadline)
                    } else {
                        scheduleRetry(after: reason, codeRejected: link.keyMismatch)
                    }
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

    /// The link for the route after `index`, made the current one, or nil once the session is closed.
    private func nextRoute(after index: Int, deadline: Double) -> Link? {
        lock.lock(); defer { lock.unlock() }
        guard open else { return nil }
        let link = makeLink(route: index + 1, deadline: deadline)
        _current = link
        return link
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
        let delay = Self.retryDelay(attempt: n)
        log.info("link failed (\(reason, privacy: .public)); retry \(n) in \(delay)s")
        stateOut.yield(.reconnecting(attempt: n, delay: delay))
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
            self?.attemptConnection()
        }
    }

    /// Seconds to wait before attempt `n` after a drop (1 is the first): 0.5, 1, 2 and 4 s, then every 5 s.
    static func retryDelay(attempt n: Int) -> Double { min(5, 0.5 * pow(2, Double(max(0, n - 1)))) }

    /// Ends the session on its final state (`.codeRejected` or `.closed`).
    private func end(_ final: State) {
        lock.lock(); open = false; lock.unlock()
        stateOut.yield(final); stateOut.finish(); messageOut.finish()
    }
}
