import Foundation
import Network
import NitidoCore
import os

private let log = Logger(subsystem: "ai.ronar.nitido", category: "session")

/// A viewer-side connection that survives drops: reconnects with backoff (0.5, 1, 2, 5 s) while open.
/// A failure before the first ready state is treated as a bad code and ends the session, and so does a reconnect the
/// sharer turns away with another key: its code changed (a new one every launch, or after three failed handshakes).
public final class LinkSession: @unchecked Sendable {
    public enum State: Sendable, Equatable {
        case connecting(attempt: Int)
        case ready
        case reconnecting(attempt: Int, delay: Double)
        case closed(String?)
    }

    public let messages: AsyncStream<Message>
    public let states: AsyncStream<State>
    public var lastRTTMs: Double? { current?.lastRTTMs }
    public var clockOffsetNs: Int64? { current?.clockOffsetNs }
    public var backlogBytes: Int { current?.backlogBytes ?? 0 }

    private let endpoint: NWEndpoint, code: String, sharerName: String, hello: Hello
    private let lock = NSLock()
    private var _current: Link?
    private var current: Link? { lock.lock(); defer { lock.unlock() }; return _current }
    private var open = true
    private var attempt = 0
    private var everReady = false
    private let messageOut: AsyncStream<Message>.Continuation
    private let stateOut: AsyncStream<State>.Continuation

    public init(endpoint: NWEndpoint, code: String, sharerName: String, hello: Hello) {
        self.endpoint = endpoint; self.code = code; self.sharerName = sharerName; self.hello = hello
        (messages, messageOut) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (states, stateOut) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(16))
    }

    public func start() { attemptConnection() }
    public func send(_ m: Message) { current?.send(m) }

    public func close() {
        lock.lock(); open = false; let link = _current; lock.unlock()
        link?.close()
        stateOut.yield(.closed(nil)); stateOut.finish(); messageOut.finish()
    }

    private func attemptConnection() {
        lock.lock()
        guard open else { lock.unlock(); return }
        attempt += 1
        let n = attempt
        let link = Link.connect(to: endpoint, code: code, sharerName: sharerName, hello: hello)
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
                    let stillOpen = lock.withLock { open }
                    if stillOpen { end("The sharer ended the session.") }
                case .connecting: break
                }
            }
        }
    }

    private func scheduleRetry(after reason: String, codeRejected: Bool) {
        // `attempt` counts the attempts since the last ready one (0 right after a drop); `n` is the one this retry makes.
        lock.lock(); let stillOpen = open, ready = everReady, n = attempt + 1; lock.unlock()
        guard stillOpen else { return }
        guard ready else { end("Could not connect. Check the code and try again."); return }
        // The sharer answered, but with a key this code does not make: it was relaunched (a new code every launch) or
        // rotated its code. No retry can pass, and each one would count there as a failed handshake, three of which
        // rotate its code again under whoever is typing it: end the session and ask for the code it shows now.
        guard !codeRejected else {
            log.error("reconnect refused: the sharer no longer takes this code (\(reason, privacy: .public))")
            end("The code on \(sharerName) has changed. Enter the new code to connect again.")
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

    private func end(_ reason: String) {
        lock.lock(); open = false; lock.unlock()
        stateOut.yield(.closed(reason)); stateOut.finish(); messageOut.finish()
    }
}
