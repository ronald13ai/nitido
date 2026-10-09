import Foundation
import Network
import os

/// A plain TCP listener that accepts connections and never sends a byte: a TLS handshake against it stalls without
/// Network.framework ever reporting `.waiting`, as a peer that never answers would.
public final class SilentListener: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "test.silent")
    private let lock = NSLock()
    private var connections: [NWConnection] = []

    public init() throws {
        listener = try NWListener(using: .tcp)
        listener.newConnectionHandler = { [weak self] c in
            guard let self else { return }
            c.start(queue: queue)
            lock.withLock { connections.append(c) }
        }
    }

    /// Connections accepted so far.
    public var accepted: Int { lock.withLock { connections.count } }

    public func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<UInt16, Error>) in
            let once = OSAllocatedUnfairLock(initialState: false)
            listener.stateUpdateHandler = { [weak self] s in
                switch s {
                case .ready:
                    guard let port = self?.listener.port?.rawValue, once.withLock({ done in defer { done = true }; return !done }) else { return }
                    c.resume(returning: port)
                case .failed(let e):
                    if once.withLock({ done in defer { done = true }; return !done }) { c.resume(throwing: e) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        listener.cancel()
        lock.withLock { connections.forEach { $0.cancel() }; connections.removeAll() }
    }
}
