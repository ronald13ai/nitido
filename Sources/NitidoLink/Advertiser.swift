import Foundation
import Network
import NitidoCore
import os

private let log = Logger(subsystem: "ai.ronar.nitido", category: "advertiser")

/// Listens with the pairing code's key and advertises `_nitido._tcp` on the local network.
public final class Advertiser: @unchecked Sendable {
    /// What the listener is doing, so the sharer UI never shows a live share on a dead listener.
    /// `.failed` and `.stopped` are final: `states` and `incoming` both end right after them.
    public enum State: Sendable, Equatable {
        case ready(port: UInt16)
        /// Bonjour registered the service under `name`: the one asked for, or "Name (2)" when another service on the
        /// network has it already. Viewers list it under this name. Not final; it comes again if the name changes.
        case advertised(name: String)
        case waiting(String)
        case failed(String)
        case stopped
    }

    public let incoming: AsyncStream<Link>
    public let states: AsyncStream<State>
    private let out: AsyncStream<Link>.Continuation
    private let stateOut: AsyncStream<State>.Continuation
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ai.ronar.nitido.advertiser")
    /// The `start()` call still waiting for its port; taken exactly once.
    private let pendingStart = OSAllocatedUnfairLock<CheckedContinuation<UInt16, Error>?>(initialState: nil)
    /// What every new connection says first (`Link`); `update(hello:)` replaces it when the capture size changes.
    private let hello: OSAllocatedUnfairLock<Hello>

    public init(name: String, code: String, hello: Hello, port: UInt16? = nil) throws {
        let params = LinkTLS.parameters(code: code, sharerName: name)
        listener = try port.map { try NWListener(using: params, on: NWEndpoint.Port(rawValue: $0)!) } ?? NWListener(using: params)
        listener.service = NWListener.Service(name: name, type: "_nitido._tcp", txtRecord: NWTXTRecord(["v": "\(protocolVersion)", "name": name]))
        (incoming, out) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (states, stateOut) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(16))
        self.hello = OSAllocatedUnfairLock(initialState: hello)
        listener.serviceRegistrationUpdateHandler = { [weak self] change in self?.registrationChanged(change) }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let link = Link(connection: connection, role: .share, hello: self.hello.withLock { $0 })
            link.start()
            out.yield(link)
        }
    }

    /// Starts listening and returns the bound port once ready. Throws if the listener fails, or is stopped,
    /// before it is ready; later changes arrive on `states`.
    public func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<UInt16, Error>) in
            pendingStart.withLock { $0 = c }
            listener.stateUpdateHandler = { [weak self] s in self?.listenerStateChanged(s) }
            listener.start(queue: queue)
        }
    }

    /// The hello that connections from now on say first: the capture's new pixel size and scale.
    public func update(hello: Hello) { self.hello.withLock { $0 = hello } }

    public func stop() {
        listener.cancel()
        out.finish()
        stateOut.yield(.stopped); stateOut.finish()
    }

    /// Reacts to one listener state. Called on `queue` by the listener (and directly by tests).
    func listenerStateChanged(_ s: NWListener.State) {
        switch s {
        case .ready:
            guard let port = listener.port?.rawValue else { return }
            stateOut.yield(.ready(port: port))
            takePendingStart()?.resume(returning: port)
        case .waiting(let e):
            log.error("listener waiting: \(e.localizedDescription, privacy: .public)")
            stateOut.yield(.waiting(e.plainDescription))
        case .failed(let e):
            // Also after start() has returned: the share is no longer reachable, so say so and end both streams.
            log.error("listener failed: \(e.localizedDescription, privacy: .public)")
            stateOut.yield(.failed(e.plainDescription)); stateOut.finish()
            out.finish()
            listener.cancel()
            takePendingStart()?.resume(throwing: e)
        case .cancelled:
            out.finish()
            stateOut.yield(.stopped); stateOut.finish()
            takePendingStart()?.resume(throwing: CancellationError())
        default: break
        }
    }

    /// Reacts to a change in the Bonjour registration. Called on `queue` by the listener (and directly by tests).
    func registrationChanged(_ change: NWListener.ServiceRegistrationChange) {
        guard case .add(.service(let name, _, _, _)) = change else { return }
        log.info("registered on the local network as \(name, privacy: .public)")
        stateOut.yield(.advertised(name: name))
    }

    private func takePendingStart() -> CheckedContinuation<UInt16, Error>? {
        pendingStart.withLock { pending in defer { pending = nil }; return pending }
    }
}
