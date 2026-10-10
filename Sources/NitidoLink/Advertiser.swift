import Foundation
import Network
import NitidoCore
import os

private let log = Logger(subsystem: "ai.ronar.nitido", category: "advertiser")

/// Listens with the pairing code's key and advertises `_nitido._tcp` on the local network. The service's TXT record
/// carries the name the key was derived from, the protocol version, and once the listener is ready its port and this
/// Mac's IPv4 addresses (`txtRecord`), so a viewer can connect to one address instead of the Bonjour service (`Peer`).
/// The addresses are published again whenever they change (a new DHCP lease, another network), so a viewer never
/// spends its time on an address this Mac no longer has.
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
    /// The name the key was derived from, which the TXT record publishes.
    private let name: String
    /// Watches this Mac's networks once the listener is ready, so the TXT record follows its addresses (`republish`).
    private let paths = NWPathMonitor()
    /// The addresses the TXT record publishes now. Only touched on `queue`.
    private var published: [IPv4Address] = []

    public init(name: String, code: String, hello: Hello, port: UInt16? = nil) throws {
        let params = LinkTLS.parameters(code: code, sharerName: name)
        listener = try port.map { try NWListener(using: params, on: NWEndpoint.Port(rawValue: $0)!) } ?? NWListener(using: params)
        self.name = name
        // Registered once the listener is ready (`listenerStateChanged`): only then is the port known, which the TXT
        // record carries.
        (incoming, out) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (states, stateOut) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(16))
        self.hello = OSAllocatedUnfairLock(initialState: hello)
        listener.serviceRegistrationUpdateHandler = { [weak self] change in self?.registrationChanged(change) }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let link = Link(connection: connection, role: .share, hello: self.hello.withLock { $0 })
            link.start()
            deliver(link)
        }
    }

    /// Puts a connection the listener took on `incoming`. Internal so a test can put one there as the listener does, just
    /// before the share stops this listener (`ShareModel.rotateCode`).
    func deliver(_ link: Link) { out.yield(link) }

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
        paths.cancel()
        listener.cancel()
        out.finish()
        stateOut.yield(.stopped); stateOut.finish()
    }

    /// Reacts to one listener state. Called on `queue` by the listener (and directly by tests).
    func listenerStateChanged(_ s: NWListener.State) {
        switch s {
        case .ready:
            guard let port = listener.port?.rawValue else { return }
            let addresses = Self.localIPv4Addresses()
            let shown = addresses.map { "\($0)" }.joined(separator: ", ")
            log.info("advertising port \(port, privacy: .public) on \(shown.isEmpty ? "no IPv4 address" : shown, privacy: .public)")
            // Set again on a later `.ready` (after a wait), which updates the TXT record (`nw_listener_set_advertise_descriptor`).
            published = addresses
            listener.service = NWListener.Service(name: name, type: Self.serviceType,
                                                  txtRecord: Self.txtRecord(name: name, port: port, addresses: addresses))
            if paths.pathUpdateHandler == nil {
                paths.pathUpdateHandler = { [weak self] _ in self?.republish(addresses: Self.localIPv4Addresses()) }
                paths.start(queue: queue)
            }
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
            paths.cancel()
            listener.cancel()
            takePendingStart()?.resume(throwing: e)
        case .cancelled:
            paths.cancel()
            out.finish()
            stateOut.yield(.stopped); stateOut.finish()
            takePendingStart()?.resume(throwing: CancellationError())
        default: break
        }
    }

    /// On `queue`, when this Mac's networks change: publishes `addresses` in the TXT record if they are not the ones it
    /// carries already, on the port the listener is ready on.
    func republish(addresses: [IPv4Address]) {
        guard addresses != published, case .ready = listener.state, let port = listener.port?.rawValue else { return }
        published = addresses
        let shown = addresses.map { "\($0)" }.joined(separator: ", ")
        log.info("this Mac's addresses changed; advertising port \(port, privacy: .public) on \(shown.isEmpty ? "no IPv4 address" : shown, privacy: .public)")
        listener.service = NWListener.Service(name: name, type: Self.serviceType,
                                              txtRecord: Self.txtRecord(name: name, port: port, addresses: addresses))
    }

    /// Test only: `republish` on `queue`, as the path monitor calls it, and the TXT record published afterwards.
    func republishForTesting(addresses: [IPv4Address]) -> NWTXTRecord? {
        queue.sync {
            republish(addresses: addresses)
            return listener.service?.txtRecordObject
        }
    }

    /// Reacts to a change in the Bonjour registration. Called on `queue` by the listener (and directly by tests).
    func registrationChanged(_ change: NWListener.ServiceRegistrationChange) {
        guard case .add(.service(let name, _, _, _)) = change else { return }
        log.info("registered on the local network as \(name, privacy: .public)")
        stateOut.yield(.advertised(name: name))
    }

    static let serviceType = "_nitido._tcp"

    /// At most this many addresses go in the TXT record; a viewer tries two (`Peer.routes(on:)`).
    static let maxPublishedAddresses = 4

    /// The TXT record: the protocol version (`v`), the name the key was derived from (`name`, since Bonjour may show the
    /// service renamed), the listener's port (`port`) and this Mac's IPv4 addresses, comma separated (`addrs`).
    /// `Browser.peer` reads it back.
    static func txtRecord(name: String, port: UInt16, addresses: [IPv4Address]) -> NWTXTRecord {
        var txt = NWTXTRecord(["v": "\(protocolVersion)", "name": name, "port": "\(port)"])
        let published = addresses.prefix(maxPublishedAddresses).map { "\($0)" }
        if !published.isEmpty { txt["addrs"] = published.joined(separator: ",") }
        return txt
    }

    /// This Mac's IPv4 addresses on interfaces that are up and running, loopback and point-to-point links (VPN tunnels)
    /// left out: Wi-Fi and Ethernet (`en0`, `en1`...) first, in interface order, then the rest (a bridge, Internet
    /// Sharing), self-assigned 169.254 addresses last. No interface scope: the address alone is what a viewer dials.
    public static func localIPv4Addresses() -> [IPv4Address] {
        var found: [(rank: Int, address: IPv4Address)] = []
        for interface in IPv4Interface.all()
        where interface.isUpAndRunning && !interface.isLoopback && !interface.isPointToPoint
            && !found.contains(where: { $0.address == interface.address }) {
            let address = interface.address
            found.append((address.isLinkLocal ? 2 : interface.name.hasPrefix("en") ? 0 : 1, address))
        }
        // A stable sort: interfaces of one rank keep the order the system lists them in.
        return found.enumerated()
            .sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }
            .map(\.element.address)
    }

    private func takePendingStart() -> CheckedContinuation<UInt16, Error>? {
        pendingStart.withLock { pending in defer { pending = nil }; return pending }
    }
}
