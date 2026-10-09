import Foundation
import Network
import os

private let log = Logger(subsystem: "ai.ronar.nitido", category: "browser")

public struct Peer: Identifiable, Hashable, Sendable {
    public let id: String
    /// The service name Bonjour shows. On a clash with another service it is renamed, as "Name (2)".
    public let name: String
    /// The name the sharer derived its key from (`Pairing.presharedKey`), from its TXT record; `name` without one.
    public let keyName: String
    /// The Bonjour service (in tests, any endpoint): the last route a viewer tries.
    public let endpoint: NWEndpoint
    /// The IPv4 addresses the sharer published in its TXT record, Wi-Fi and Ethernet first; none from a sharer that
    /// publishes none.
    public let addresses: [IPv4Address]
    /// The port the sharer's listener is on, from its TXT record.
    public let port: UInt16?

    public init(id: String, name: String, keyName: String, endpoint: NWEndpoint, addresses: [IPv4Address] = [], port: UInt16? = nil) {
        self.id = id; self.name = name; self.keyName = keyName; self.endpoint = endpoint
        self.addresses = addresses; self.port = port
    }

    /// Where a viewer on `subnets` (its own networks, `IPv4Subnet.local`) tries to reach the sharer, in order
    /// (`LinkSession`): the first address the sharer published on one of those networks, the next one, then the Bonjour
    /// service. Most likely reading of the two-Mac logs (2026-10-09): the Bonjour service resolves to every address the
    /// sharer has (IPv6 link-local, IPv4, AWDL), which Network.framework tries one after another, so a wrong code through
    /// it failed the handshake several times on the sharer and never came back to the viewer, which gave up after its
    /// deadline. One address gives one handshake, whose failure comes back as on one Mac. An address on none of the
    /// viewer's networks (a desktop's Ethernet on another network, a sharer found only over AWDL) is not dialled: its
    /// silence would only take time from the Bonjour service, the one route that can work then.
    public func routes(on subnets: [IPv4Subnet]) -> [NWEndpoint] {
        let published = port.flatMap { NWEndpoint.Port(rawValue: $0) }.map { port in
            addresses.filter { address in subnets.contains { $0.contains(address) } }
                .prefix(2).map { NWEndpoint.hostPort(host: .ipv4($0), port: port) }
        } ?? []
        return published.filter { $0 != endpoint } + [endpoint]
    }
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
        // With the TXT record: Bonjour renames a service whose name is taken, but the key stays derived from the name
        // the sharer asked for, which `Advertiser` publishes there.
        browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_nitido._tcp", domain: nil), using: params)
        (peers, out) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (states, stateOut) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(16))
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let list = results.compactMap { Self.peer(endpoint: $0.endpoint, metadata: $0.metadata) }.sorted { $0.name < $1.name }
            self?.out.yield(list)
        }
        browser.stateUpdateHandler = { [weak self] s in self?.browserStateChanged(s) }
    }

    public func start() { browser.start(queue: queue) }

    /// The peer a browse result describes, or nil for one that is not a Bonjour service. Its TXT record
    /// (`Advertiser.txtRecord`) comes from the network: only plain dotted IPv4 unicast addresses and a port above 0 are
    /// taken, the rest is ignored.
    static func peer(endpoint: NWEndpoint, metadata: NWBrowser.Result.Metadata) -> Peer? {
        guard case .service(let name, _, _, _) = endpoint else { return nil }
        var keyName = name, addresses: [IPv4Address] = [], port: UInt16?
        if case .bonjour(let txt) = metadata {
            if let published = txt["name"], !published.isEmpty { keyName = published }
            addresses = (txt["addrs"] ?? "").split(separator: ",", omittingEmptySubsequences: true)
                .compactMap { unicastIPv4(String($0)) }
                .prefix(Advertiser.maxPublishedAddresses).map { $0 }
            port = txt["port"].flatMap { UInt16($0) }.flatMap { $0 > 0 ? $0 : nil }
        }
        return Peer(id: "\(endpoint)", name: name, keyName: keyName, endpoint: endpoint, addresses: addresses, port: port)
    }

    /// `text` as an IPv4 address a sharer could listen on: four decimal parts of 0 to 255, and not loopback, the
    /// unspecified address, multicast or broadcast. `IPv4Address` alone also takes "1.2.3" and an interface ("%en0").
    private static func unicastIPv4(_ text: String) -> IPv4Address? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4,
              parts.allSatisfy({ (1...3).contains($0.count) && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) && Int($0)! <= 255 }),
              let address = IPv4Address(text),
              !address.isLoopback, !address.isMulticast, address != .any, address != .broadcast
        else { return nil }
        return address
    }

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
