import Foundation
import Network
import QuartzCore
import NitidoCore
import os

private let log = Logger(subsystem: "ai.ronar.nitido", category: "link")

/// One encrypted connection. Frames messages, answers pings, measures RTT and clock offset, tracks send backlog.
public final class Link: @unchecked Sendable {
    public enum State: Sendable, Equatable { case connecting, ready, failed(String), cancelled }

    public let role: Role
    public let messages: AsyncStream<Message>
    public let states: AsyncStream<State>
    public private(set) var state: State = .connecting
    public private(set) var peerHello: Hello?
    public private(set) var lastRTTMs: Double?
    /// Peer clock minus local clock, nanoseconds, estimated from ping/pong (nil until the first pong).
    public private(set) var clockOffsetNs: Int64?
    public var backlogBytes: Int { lock.lock(); defer { lock.unlock() }; return backlog }

    private let connection: NWConnection
    private let hello: Hello
    private let queue = DispatchQueue(label: "ai.ronar.nitido.link", qos: .userInteractive)
    private let lock = NSLock()
    private var backlog = 0
    private var decoder = Wire.Decoder()
    private var pingTimer: DispatchSourceTimer?
    private var nextPing: UInt32 = 0
    private var pingSentAt: [UInt32: Double] = [:]
    private let messageOut: AsyncStream<Message>.Continuation
    private let stateOut: AsyncStream<State>.Continuation

    init(connection: NWConnection, role: Role, hello: Hello) {
        self.connection = connection; self.role = role; self.hello = hello
        (messages, messageOut) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (states, stateOut) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(16))
    }

    public static func connect(to endpoint: NWEndpoint, code: String, sharerName: String, hello: Hello) -> Link {
        let link = Link(connection: NWConnection(to: endpoint, using: LinkTLS.parameters(code: code, sharerName: sharerName)), role: .view, hello: hello)
        link.start()
        return link
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] s in
            guard let self else { return }
            switch s {
            case .ready:
                setState(.ready); send(.hello(hello)); receiveLoop(); startPings()
            case .failed(let e): finish(.failed(e.localizedDescription))
            case .cancelled: finish(.cancelled)
            case .waiting(let e):
                // A failed TLS handshake (wrong code) parks a client connection in .waiting, where
                // Network.framework would retry the same doomed handshake forever: end it as a failure.
                if case .tls = e {
                    log.error("handshake failed: \(e.localizedDescription, privacy: .public)")
                    finish(.failed(e.localizedDescription)); connection.cancel()
                } else {
                    log.info("waiting: \(e.localizedDescription)")
                }
            default: break
            }
        }
        connection.start(queue: queue)
    }

    public func send(_ m: Message) {
        let data = Wire.encode(m)
        lock.lock(); backlog += data.count; lock.unlock()
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            lock.lock(); backlog -= data.count; lock.unlock()
            if let error { log.error("send: \(error.localizedDescription)") }
        })
    }

    public func close() {
        pingTimer?.cancel(); pingTimer = nil
        connection.send(content: Wire.encode(.bye(reason: 0)), completion: .contentProcessed { [weak self] _ in self?.connection.cancel() })
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do { for m in try decoder.feed(data) { handle(m) } }
                catch { finish(.failed("protocol: \(error)")); connection.cancel(); return }
            }
            if let error { finish(.failed(error.localizedDescription)); return }
            if complete { finish(.cancelled); return }
            receiveLoop()
        }
    }

    private func handle(_ m: Message) {
        let now = CACurrentMediaTime()
        switch m {
        case .hello(let h):
            peerHello = h
            if h.protocolVersion != protocolVersion { send(.bye(reason: 1)); finish(.failed("protocol version \(h.protocolVersion), expected \(protocolVersion)")); connection.cancel(); return }
            messageOut.yield(m)
        case .ping(let id, let t):
            send(.pong(id: id, originalTNs: t, replyTNs: UInt64(now * 1e9)))
        case .pong(let id, let original, let reply):
            lock.lock(); let sent = pingSentAt.removeValue(forKey: id); lock.unlock()
            guard sent != nil else { return }
            let t0 = Double(original) / 1e9, t3 = now
            lastRTTMs = (t3 - t0) * 1000
            clockOffsetNs = Int64(reply) - Int64(((t0 + t3) / 2) * 1e9)
        case .bye:
            finish(.cancelled); connection.cancel()
        default:
            messageOut.yield(m)
        }
    }

    private func startPings() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            lock.lock(); nextPing &+= 1; let id = nextPing; pingSentAt[id] = CACurrentMediaTime(); pingSentAt = pingSentAt.filter { CACurrentMediaTime() - $0.value < 10 }; lock.unlock()
            send(.ping(id: id, tNs: UInt64(CACurrentMediaTime() * 1e9)))
        }
        timer.resume()
        pingTimer = timer
    }

    private func setState(_ s: State) { state = s; stateOut.yield(s) }

    private func finish(_ s: State) {
        guard state == .ready || state == .connecting else { return }
        pingTimer?.cancel(); pingTimer = nil
        setState(s)
        messageOut.finish(); stateOut.finish()
    }
}
