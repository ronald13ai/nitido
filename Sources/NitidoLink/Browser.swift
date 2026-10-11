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
    /// (`LinkSession`): two of the addresses the sharer published (`dialled(on:)`), then the Bonjour service. Most likely
    /// reading of the two-Mac logs (2026-10-09): the Bonjour service resolves to every address the sharer has (IPv6
    /// link-local, IPv4, AWDL), which Network.framework tries one after another, so a wrong code through it failed the
    /// handshake several times on the sharer and never came back to the viewer, which gave up after its deadline. One
    /// address gives one handshake, whose failure comes back as on one Mac.
    public func routes(on subnets: [IPv4Subnet]) -> [NWEndpoint] {
        let published = port.flatMap { NWEndpoint.Port(rawValue: $0) }.map { port in
            dialled(on: subnets).map { NWEndpoint.hostPort(host: .ipv4($0), port: port) }
        } ?? []
        return published.filter { $0 != endpoint } + [endpoint]
    }

    /// The published addresses a viewer on `subnets` dials, at most two, in order: those on one of its networks first,
    /// then the others, each group in the order the sharer published them. An address on another network still comes
    /// before the Bonjour service, since it may be the only way through: a sharer on another VLAN behind an mDNS
    /// reflector, or one with only a self-assigned 169.254 address. Put after the ones on the viewer's networks, it does
    /// not hold up the address that works: a desktop Mac publishes its Ethernet first, wherever that is. None without a
    /// port.
    func dialled(on subnets: [IPv4Subnet]) -> [IPv4Address] {
        guard port != nil else { return [] }
        let onOne = { (address: IPv4Address) in subnets.contains { $0.contains(address) } }
        return Array((addresses.filter(onOne) + addresses.filter { !onOne($0) }).prefix(2))
    }
}

/// Finds sharers on the local network; emits the full list on every change.
///
/// Peer-to-peer Wi-Fi (AWDL) is on while it browses with `includePeerToPeer`, and the Wi-Fi radio then time-slices
/// between the network's channel and AWDL's, which costs the network throughput and latency: jitter in the very figures
/// the strip measures. A viewer connected through an address the sharer published needs no AWDL, so it browses without
/// it then (`usePeerToPeer`), and with it again once the link drops or the session ends.
public final class Browser: @unchecked Sendable {
    /// What discovery is doing, so the viewer UI can say why the list is empty (Local Network denied, DNS-SD
    /// error) instead of waiting in silence. `.failed` and `.stopped` are final: `states` and `peers` end after them.
    public enum State: Sendable, Equatable { case ready, waiting(String), failed(String), stopped }

    public let peers: AsyncStream<[Peer]>
    public let states: AsyncStream<State>
    private let out: AsyncStream<[Peer]>.Continuation
    private let stateOut: AsyncStream<State>.Continuation
    private let queue = DispatchQueue(label: "ai.ronar.nitido.browser")
    // Only touched on `queue`, apart from `init`.
    /// The browser running now; `usePeerToPeer` replaces it with one that browses the other way.
    private var browser: NWBrowser
    private var started = false, stopped = false

    /// `peerToPeer` false browses without AWDL.
    public init(peerToPeer: Bool = true) {
        (peers, out) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (states, stateOut) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(16))
        browser = Self.makeBrowser(peerToPeer: peerToPeer)
        follow(browser)
    }

    private static func makeBrowser(peerToPeer: Bool) -> NWBrowser {
        let params = NWParameters(); params.includePeerToPeer = peerToPeer
        // With the TXT record: Bonjour renames a service whose name is taken, but the key stays derived from the name
        // the sharer asked for, which `Advertiser` publishes there.
        return NWBrowser(for: .bonjourWithTXTRecord(type: "_nitido._tcp", domain: nil), using: params)
    }

    /// Hears `b`'s results and states for as long as it is the browser running; a browser replaced since says nothing.
    private func follow(_ b: NWBrowser) {
        b.browseResultsChangedHandler = { [weak self, weak b] results, _ in
            guard let self, let b, b === browser else { return }
            let list = results.compactMap { Self.peer(endpoint: $0.endpoint, metadata: $0.metadata) }.sorted { $0.name < $1.name }
            out.yield(list)
        }
        b.stateUpdateHandler = { [weak self, weak b] s in
            guard let self, let b, b === browser else { return }
            browserStateChanged(s)
        }
    }

    public func start() { queue.sync { started = true; browser.start(queue: queue) } }

    /// Browses with AWDL (`true`) or without it from now on, if it does not already, by replacing the browser: an
    /// `NWBrowser`'s parameters cannot change once it runs. The list starts again from what the new browser finds,
    /// within about a second, so a list the old one saw never outlives it. Nothing before `start` or after `stop`.
    public func usePeerToPeer(_ on: Bool) {
        queue.async { [self] in
            guard started, !stopped, browser.parameters.includePeerToPeer != on else { return }
            log.info("\(on ? "browsing with peer-to-peer Wi-Fi again" : "connected through a published address; browsing without peer-to-peer Wi-Fi", privacy: .public)")
            let old = browser
            browser = Self.makeBrowser(peerToPeer: on)
            follow(browser)
            out.yield([])
            browser.start(queue: queue)
            old.cancel()
        }
    }

    /// Test only: whether the browser running now browses with AWDL.
    var includesPeerToPeerForTesting: Bool { queue.sync { browser.parameters.includePeerToPeer } }

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
        queue.sync { stopped = true; browser.cancel() }
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
