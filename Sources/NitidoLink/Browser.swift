import Foundation
import Network
import os

private let log = Logger(subsystem: "ai.ronar.nitido", category: "browser")

public struct Peer: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let endpoint: NWEndpoint
}

/// Finds sharers on the local network; emits the full list on every change.
public final class Browser: @unchecked Sendable {
    /// What discovery is doing, so the viewer UI can say why the list is empty (Local Network denied, DNS-SD
    /// error) instead of waiting in silence. `.failed` and `.stopped` are final: `states` and `peers` end after them.
    public enum State: Sendable, Equatable { case ready, waiting(String), failed(String), stopped }

    public let peers: AsyncStream<[Peer]>
    public let states: AsyncStream<State>
    private let out: AsyncStream<[Peer]>.Continuation
    private let stateOut: AsyncStream<State>.Continuation
    private let browser: NWBrowser
    private let queue = DispatchQueue(label: "ai.ronar.nitido.browser")

    public init() {
        let params = NWParameters(); params.includePeerToPeer = true
        browser = NWBrowser(for: .bonjour(type: "_nitido._tcp", domain: nil), using: params)
        (peers, out) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (states, stateOut) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(16))
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let list = results.compactMap { r -> Peer? in
                guard case .service(let name, _, _, _) = r.endpoint else { return nil }
                return Peer(id: "\(r.endpoint)", name: name, endpoint: r.endpoint)
            }.sorted { $0.name < $1.name }
            self?.out.yield(list)
        }
        browser.stateUpdateHandler = { [weak self] s in self?.browserStateChanged(s) }
    }

    public func start() { browser.start(queue: queue) }

    public func stop() {
        browser.cancel()
        out.finish()
        stateOut.yield(.stopped); stateOut.finish()
    }

    /// Reacts to one browser state. Called on `queue` by the browser (and directly by tests).
    func browserStateChanged(_ s: NWBrowser.State) {
        switch s {
        case .ready:
            stateOut.yield(.ready)
        case .waiting(let e):
            // Local Network denied lands here (DNS-SD PolicyDenied); the browser resumes by itself once allowed.
            log.error("browse waiting: \(e.localizedDescription, privacy: .public)")
            stateOut.yield(.waiting(e.plainDescription))
        case .failed(let e):
            log.error("browse failed: \(e.localizedDescription, privacy: .public)")
            stateOut.yield(.failed(e.plainDescription)); stateOut.finish()
            // The last list is stale once discovery is dead.
            out.yield([]); out.finish()
            browser.cancel()
        case .cancelled:
            out.finish()
            stateOut.yield(.stopped); stateOut.finish()
        default: break
        }
    }
}
