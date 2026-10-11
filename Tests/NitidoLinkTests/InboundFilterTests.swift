import XCTest
import Network
@testable import NitidoLink
@testable import NitidoCore

/// Spec 13: the sharer's listener takes connections from the local network only, and judges it before the handshake.
final class InboundFilterTests: XCTestCase {
    private let home = LocalNetworks(
        pointToPoint: ["utun3", "ipsec0"],
        prefixes: [NetworkPrefix(address: [203, 0, 113, 20], mask: [255, 255, 255, 0]),
                   NetworkPrefix(address: [0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 1] + [UInt8](repeating: 0, count: 7) + [9],
                                 mask: [UInt8](repeating: 0xff, count: 8) + [UInt8](repeating: 0, count: 8))])

    private func verdict(_ host: NWEndpoint.Host, over interface: String? = "en0",
                         type: NWInterface.InterfaceType? = .wifi) -> String? {
        InboundFilter.rejection(remote: .hostPort(host: host, port: 50_000), interfaceName: interface, interfaceType: type,
                                networks: home)
    }

    /// Private, self-assigned, loopback and link-local addresses are the local network, and so is any address on one of
    /// this Mac's own networks (a campus LAN of public IPv4 addresses, the IPv6 prefix the router hands out).
    func testTheLocalNetworkIsLetIn() {
        for host: NWEndpoint.Host in ["192.168.1.7", "10.0.4.2", "172.20.1.1", "169.254.10.3", "127.0.0.1", "203.0.113.77",
                                      "::1", "fe80::1%en0", "fd12:3456::7", "2001:db8:0:1::42", "::ffff:192.168.1.7"] {
            XCTAssertNil(verdict(host), "\(host) is on the local network")
        }
        XCTAssertNil(verdict("10.20.0.5", over: nil, type: nil), "a private address on another VLAN, behind an mDNS reflector (spec 4)")
    }

    /// A public address on none of this Mac's networks is not the local network: a globally routable IPv6 address the
    /// router lets through, an IPv4 one forwarded to this Mac, carrier-grade NAT's 100.64/10 (a mesh VPN).
    func testAPublicAddressOnNoneOfThisMacsNetworksIsTurnedAway() {
        for host: NWEndpoint.Host in ["8.8.8.8", "100.100.1.2", "2a00:1450:4001::1", "2001:db8:0:2::42", "::ffff:8.8.8.8"] {
            let reason = verdict(host)
            XCTAssertNotNil(reason, "\(host) is not on the local network")
            XCTAssertTrue(reason?.contains("neither a private address nor on this Mac's networks") == true, reason ?? "")
        }
    }

    /// A VPN tunnel carries private addresses too (a corporate 10/8): what it comes over decides, and cellular is never
    /// the local network.
    func testAConnectionOverAVPNTunnelOrCellularIsTurnedAway() {
        XCTAssertEqual(verdict("10.8.0.5", over: "utun3", type: .other), "it came over utun3, a VPN tunnel or another point-to-point link")
        XCTAssertNotNil(verdict("fe80::5%utun3", over: nil, type: nil), "a link-local address scoped to a tunnel")
        XCTAssertEqual(verdict("192.168.1.7", over: "pdp_ip0", type: .cellular), "it came over a cellular interface")
        XCTAssertNil(verdict("fe80::a410:82ff:fe92:a772%awdl0", over: "awdl0", type: .other),
                     "AWDL is a broadcast link to the Mac next to this one, not a tunnel")
    }

    /// The real listener: a connection over a path that is not the local network is cancelled before its handshake, so
    /// the right code does not pair, nothing reaches the share, and it never counts as a wrong code. The loopback
    /// interface stands in for a tunnel here: the test says it is one.
    func testAConnectionOverANonLocalPathIsCancelledBeforeItsHandshake() async throws {
        let name = "Filter \(UInt32.random(in: 0..<1_000_000))"
        let hello = Hello(protocolVersion: protocolVersion, role: .share, name: name, pixelWidth: 320, pixelHeight: 180, scale: 2)
        let advertiser = try Advertiser(name: name, code: "4321", hello: hello,
                                        networks: { LocalNetworks(pointToPoint: ["lo0"], prefixes: []) })
        let port = try await advertiser.start()
        defer { advertiser.stop() }
        let delivered = Task { () -> Bool in for await _ in advertiser.incoming { return true }; return false }

        let viewer = Link.connect(to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!), code: "4321",
                                  sharerName: name,
                                  hello: Hello(protocolVersion: protocolVersion, role: .view, name: "Viewer", pixelWidth: 0, pixelHeight: 0, scale: 2),
                                  connectTimeout: 4, waitingTimeout: 1)
        defer { viewer.close() }
        var ended: Link.State?
        for await s in viewer.states where s != .connecting { ended = s; break }
        guard case .failed = ended else { return XCTFail("the right code over a non-local path must not pair: \(String(describing: ended))") }
        XCTAssertFalse(viewer.wasReady, "TLS never came up")
        XCTAssertFalse(viewer.keyMismatch, "no handshake ran, so nothing failed on the keys")
        XCTAssertEqual(advertiser.rejectedForTesting, 1)
        advertiser.stop()
        let reachedTheShare = await delivered.value
        XCTAssertFalse(reachedTheShare, "nothing reaches the share's incoming connections")
    }

    /// The same listener lets a loopback connection in when loopback is not said to be a tunnel: what the app's own
    /// two-copies-on-one-Mac setup uses.
    func testALocalConnectionPairs() async throws {
        let name = "Filter \(UInt32.random(in: 0..<1_000_000))"
        let hello = Hello(protocolVersion: protocolVersion, role: .share, name: name, pixelWidth: 320, pixelHeight: 180, scale: 2)
        let advertiser = try Advertiser(name: name, code: "4321", hello: hello)
        let port = try await advertiser.start()
        defer { advertiser.stop() }
        let viewer = Link.connect(to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!), code: "4321",
                                  sharerName: name,
                                  hello: Hello(protocolVersion: protocolVersion, role: .view, name: "Viewer", pixelWidth: 0, pixelHeight: 0, scale: 2))
        defer { viewer.close() }
        var sharer: Link?
        for await link in advertiser.incoming { sharer = link; break }
        defer { sharer?.close() }
        var ready = false
        for await s in viewer.states { if s == .ready { ready = true; break }; if s != .connecting { break } }
        XCTAssertTrue(ready)
        XCTAssertEqual(advertiser.rejectedForTesting, 0)
    }
}
