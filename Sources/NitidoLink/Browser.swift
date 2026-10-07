import Foundation
import Network

public struct Peer: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let endpoint: NWEndpoint
}

/// Finds sharers on the local network; emits the full list on every change.
public final class Browser: @unchecked Sendable {
    public let peers: AsyncStream<[Peer]>
    private let out: AsyncStream<[Peer]>.Continuation
    private let browser: NWBrowser
    private let queue = DispatchQueue(label: "ai.ronar.nitido.browser")

    public init() {
        let params = NWParameters(); params.includePeerToPeer = true
        browser = NWBrowser(for: .bonjour(type: "_nitido._tcp", domain: nil), using: params)
        (peers, out) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let list = results.compactMap { r -> Peer? in
                guard case .service(let name, _, _, _) = r.endpoint else { return nil }
                return Peer(id: "\(r.endpoint)", name: name, endpoint: r.endpoint)
            }.sorted { $0.name < $1.name }
            self?.out.yield(list)
        }
    }

    public func start() { browser.start(queue: queue) }
    public func stop() { browser.cancel(); out.finish() }
}
