import Foundation
import Network
import NitidoCore
import os

private let log = Logger(subsystem: "ai.ronar.nitido", category: "advertiser")

/// Listens with the pairing code's key and advertises `_nitido._tcp` on the local network.
public final class Advertiser: @unchecked Sendable {
    public let incoming: AsyncStream<Link>
    private let out: AsyncStream<Link>.Continuation
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ai.ronar.nitido.advertiser")

    public init(name: String, code: String, hello: Hello) throws {
        listener = try NWListener(using: LinkTLS.parameters(code: code, sharerName: name))
        listener.service = NWListener.Service(name: name, type: "_nitido._tcp", txtRecord: NWTXTRecord(["v": "\(protocolVersion)", "name": name]))
        (incoming, out) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let link = Link(connection: connection, role: .share, hello: hello)
            link.start()
            out.yield(link)
        }
    }

    /// Starts listening and returns the bound port once ready.
    public func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<UInt16, Error>) in
            // The state handler is @Sendable under Swift 6, so the "resumed once" flag lives behind a lock.
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let claim: @Sendable () -> Bool = { resumed.withLock { done in defer { done = true }; return !done } }
            listener.stateUpdateHandler = { [weak self] s in
                switch s {
                case .ready:
                    guard let port = self?.listener.port?.rawValue, claim() else { return }
                    c.resume(returning: port)
                case .failed(let e):
                    log.error("listener failed: \(e.localizedDescription)")
                    if claim() { c.resume(throwing: e) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() { listener.cancel(); out.finish() }
}
