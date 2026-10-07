import Foundation
import Network
import NitidoCore
import os

private let log = Logger(subsystem: "ai.ronar.nitido", category: "advertiser")

/// Listens with the pairing code's key and advertises `_nitido._tcp` on the local network.
public final class Advertiser: @unchecked Sendable {
    /// What the listener is doing, so the sharer UI never shows a live share on a dead listener.
    /// `.failed` and `.stopped` are final: `states` and `incoming` both end right after them.
    public enum State: Sendable, Equatable { case ready(port: UInt16), waiting(String), failed(String), stopped }

    public let incoming: AsyncStream<Link>
    public let states: AsyncStream<State>
    private let out: AsyncStream<Link>.Continuation
    private let stateOut: AsyncStream<State>.Continuation
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ai.ronar.nitido.advertiser")
    /// The `start()` call still waiting for its port; taken exactly once.
    private let pendingStart = OSAllocatedUnfairLock<CheckedContinuation<UInt16, Error>?>(initialState: nil)

    public init(name: String, code: String, hello: Hello) throws {
        listener = try NWListener(using: LinkTLS.parameters(code: code, sharerName: name))
        listener.service = NWListener.Service(name: name, type: "_nitido._tcp", txtRecord: NWTXTRecord(["v": "\(protocolVersion)", "name": name]))
        (incoming, out) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (states, stateOut) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(16))
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let link = Link(connection: connection, role: .share, hello: hello)
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

    private func takePendingStart() -> CheckedContinuation<UInt16, Error>? {
        pendingStart.withLock { pending in defer { pending = nil }; return pending }
    }
}
