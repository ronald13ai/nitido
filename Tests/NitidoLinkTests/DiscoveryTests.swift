import XCTest
import Network
@testable import NitidoLink
@testable import NitidoCore

/// What a viewer learns from Bonjour, and that it is enough to pair.
final class DiscoveryTests: XCTestCase {
    private func hello(_ role: Role, name: String) -> Hello {
        Hello(protocolVersion: protocolVersion, role: role, name: name, pixelWidth: 1920, pixelHeight: 1080, scale: 2)
    }

    /// The first list from `browser` that `accept` takes, or nil after `seconds`.
    private func firstList(from browser: Browser, within seconds: Double, where accept: @escaping @Sendable ([Peer]) -> Bool) async -> [Peer]? {
        await withTaskGroup(of: [Peer]?.self) { group in
            group.addTask { for await list in browser.peers where accept(list) { return list }; return nil }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Two Macs left at the default Computer Name share one name, and Bonjour registers the second as "Name (2)". Each
    /// advertiser says the name it was registered under, so the sharer can show the name its viewers see in the list.
    func testTwoSharersOfTheSameNameSayTheNameBonjourGaveThem() async throws {
        let name = "Twin \(UInt32.random(in: 0..<1_000_000))"
        let first = try Advertiser(name: name, code: "1234", hello: hello(.share, name: name))
        _ = try await first.start()
        defer { first.stop() }
        let second = try Advertiser(name: name, code: "1234", hello: hello(.share, name: name))
        _ = try await second.start()
        defer { second.stop() }
        func advertisedName(_ advertiser: Advertiser) async -> String? {
            await withTaskGroup(of: String?.self) { group in
                group.addTask {
                    for await s in advertiser.states { if case .advertised(let n) = s { return n } }
                    return nil
                }
                group.addTask { try? await Task.sleep(for: .seconds(10)); return nil }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
        }
        let names = [await advertisedName(first), await advertisedName(second)]
        XCTAssertEqual(Set(names.compactMap { $0 }), [name, "\(name) (2)"], "registered as \(names)")
    }

    /// Bonjour renames a service whose name is taken on the network ("Twin (2)"), while the sharer keyed its listener
    /// with the name it asked for. A viewer that derived the key from the name Bonjour shows would always fail as if
    /// the code were wrong: it pairs with the name the sharer publishes in its TXT record.
    func testARenamedSharerPairsUnderTheNameItKeyedItsListenerWith() async throws {
        let name = "Twin \(UInt32.random(in: 0..<1_000_000))"
        let first = try Advertiser(name: name, code: "1234", hello: hello(.share, name: name))
        _ = try await first.start()
        defer { first.stop() }
        let second = try Advertiser(name: name, code: "1234", hello: hello(.share, name: name))
        _ = try await second.start()
        defer { second.stop() }

        let browser = Browser()
        browser.start()
        defer { browser.stop() }
        let list = await firstList(from: browser, within: 10) { list in list.filter { $0.name.hasPrefix(name) }.count == 2 }
        let twins = try XCTUnwrap(list, "both advertisers should be found within 10 s").filter { $0.name.hasPrefix(name) }
        let renamed = try XCTUnwrap(twins.first { $0.name != name }, "Bonjour should have renamed one of \(twins.map(\.name))")
        XCTAssertEqual(twins.map(\.keyName), [name, name], "both publish the name they keyed their listener with")

        let viewer = Link.connect(to: renamed.endpoint, code: "1234", sharerName: renamed.keyName, hello: hello(.view, name: "Viewer"))
        defer { viewer.close() }
        var ready = false
        for await s in viewer.states {
            if s == .ready { ready = true; break }
            if case .failed = s { break }
            if s == .cancelled { break }
        }
        XCTAssertTrue(ready, "the viewer should pair with \(renamed.name) using its TXT name")
    }

    /// The sharer's TXT record names the IPv4 addresses and the port it listens on, so a viewer can connect to one
    /// address instead of the Bonjour service, which Network.framework resolves to several addresses and tries one after
    /// another. A record from a sharer that publishes none (an older build) still gives a peer, with no address.
    func testTheTXTRecordCarriesTheAddressesAndThePortAndReadsBack() throws {
        let service = NWEndpoint.service(name: "Ronald's MacBook Pro (2)", type: "_nitido._tcp", domain: "local.", interface: nil)
        let addresses = [IPv4Address("192.168.1.20")!, IPv4Address("10.0.0.5")!]
        let txt = Advertiser.txtRecord(name: "Ronald's MacBook Pro", port: 51_234, addresses: addresses)
        let peer = try XCTUnwrap(Browser.peer(endpoint: service, metadata: .bonjour(txt)))
        XCTAssertEqual(peer.name, "Ronald's MacBook Pro (2)")
        XCTAssertEqual(peer.keyName, "Ronald's MacBook Pro")
        XCTAssertEqual(peer.addresses, addresses)
        XCTAssertEqual(peer.port, 51_234)
        XCTAssertEqual(peer.endpoint, service)
        XCTAssertEqual(txt["v"], "\(protocolVersion)")

        let older = try XCTUnwrap(Browser.peer(endpoint: service, metadata: .bonjour(NWTXTRecord(["v": "1", "name": "Old Mac"]))))
        XCTAssertEqual(older.keyName, "Old Mac")
        XCTAssertEqual(older.addresses, [])
        XCTAssertNil(older.port)
        let everywhere = [IPv4Subnet(address: IPv4Address("10.0.0.1")!, mask: IPv4Address("255.0.0.0")!)]
        XCTAssertEqual(older.routes(on: everywhere), [service], "with nothing published, the Bonjour service is the only route")

        let bare = try XCTUnwrap(Browser.peer(endpoint: service, metadata: .none))
        XCTAssertEqual(bare.keyName, "Ronald's MacBook Pro (2)", "no TXT record: the key name is the name shown")
        XCTAssertEqual(bare.addresses, [])
        XCTAssertNil(bare.port)

        // Everything in a TXT record comes from the network: only plain unicast IPv4 addresses and a real port are taken.
        let forged = NWTXTRecord(["name": "Odd", "addrs": "999.1.1.1,not,127.0.0.1,1.2.3,224.0.0.1,0.0.0.0,255.255.255.255,10.0.0.7%en0, 10.0.0.8,10.0.0.9", "port": "0"])
        let odd = try XCTUnwrap(Browser.peer(endpoint: service, metadata: .bonjour(forged)))
        XCTAssertEqual(odd.addresses, [IPv4Address("10.0.0.9")!])
        XCTAssertNil(odd.port)
        XCTAssertEqual(odd.routes(on: everywhere), [service], "an address without a port is no route")
        XCTAssertNil(Browser.peer(endpoint: .hostPort(host: "10.0.0.1", port: 1), metadata: .none), "not a Bonjour service")
    }

    private func subnet(_ address: String, _ mask: String) -> IPv4Subnet {
        IPv4Subnet(address: IPv4Address(address)!, mask: IPv4Address(mask)!)
    }

    /// A viewer tries the first published address, then the next one, then the Bonjour service; never more addresses.
    func testTheRoutesAreTwoPublishedAddressesThenTheService() {
        let service = NWEndpoint.service(name: "Sharer", type: "_nitido._tcp", domain: "local.", interface: nil)
        let peer = Peer(id: "s", name: "Sharer", keyName: "Sharer", endpoint: service,
                        addresses: [IPv4Address("192.168.1.20")!, IPv4Address("10.0.0.5")!, IPv4Address("172.16.0.2")!], port: 50_000)
        let viewer = [subnet("192.168.1.31", "255.255.255.0"), subnet("10.0.0.9", "255.0.0.0"), subnet("172.16.0.9", "255.240.0.0")]
        XCTAssertEqual(peer.routes(on: viewer), [
            .hostPort(host: .ipv4(IPv4Address("192.168.1.20")!), port: 50_000),
            .hostPort(host: .ipv4(IPv4Address("10.0.0.5")!), port: 50_000),
            service,
        ])
    }

    /// Only the published addresses on one of the viewer's own networks are dialled. A desktop Mac whose Ethernet is on
    /// another network publishes that address first, and a sharer found only over AWDL publishes addresses the viewer
    /// cannot reach: dialling them cost 4 s and 2 s of silence and left the Bonjour service, the one route that works
    /// there, 2 s of the deadline.
    func testOnlyPublishedAddressesOnOneOfTheViewersNetworksAreDialled() {
        let service = NWEndpoint.service(name: "Sharer", type: "_nitido._tcp", domain: "local.", interface: nil)
        let published = ["10.20.0.7", "192.168.1.20", "192.168.1.21", "169.254.10.1"].map { IPv4Address($0)! }
        let peer = Peer(id: "s", name: "Sharer", keyName: "Sharer", endpoint: service, addresses: published, port: 50_000)
        let wifi = subnet("192.168.1.31", "255.255.255.0")
        XCTAssertEqual(peer.routes(on: [wifi]), [
            .hostPort(host: .ipv4(IPv4Address("192.168.1.20")!), port: 50_000),
            .hostPort(host: .ipv4(IPv4Address("192.168.1.21")!), port: 50_000),
            service,
        ], "the Ethernet address on another network is skipped, not tried first")
        XCTAssertEqual(peer.routes(on: [subnet("172.20.4.9", "255.255.0.0")]), [service],
                       "on none of the viewer's networks: the Bonjour service alone, with the whole deadline")
        XCTAssertEqual(peer.routes(on: []), [service])
        XCTAssertEqual(peer.routes(on: [subnet("169.254.80.2", "255.255.0.0"), wifi]), [
            .hostPort(host: .ipv4(IPv4Address("192.168.1.20")!), port: 50_000),
            .hostPort(host: .ipv4(IPv4Address("192.168.1.21")!), port: 50_000),
            service,
        ], "in the order the sharer published them")
    }

    /// A network holds the addresses whose bits under its mask match its own.
    func testANetworkHoldsTheAddressesUnderItsMask() {
        let home = subnet("192.168.1.31", "255.255.255.0")
        XCTAssertTrue(home.contains(IPv4Address("192.168.1.20")!))
        XCTAssertTrue(home.contains(IPv4Address("192.168.1.255")!))
        XCTAssertFalse(home.contains(IPv4Address("192.168.2.20")!))
        XCTAssertFalse(home.contains(IPv4Address("10.168.1.20")!))
        let office = subnet("10.20.30.40", "255.255.240.0")
        XCTAssertTrue(office.contains(IPv4Address("10.20.17.1")!))
        XCTAssertFalse(office.contains(IPv4Address("10.20.48.1")!))
        let alone = subnet("192.168.1.31", "255.255.255.255")
        XCTAssertTrue(alone.contains(IPv4Address("192.168.1.31")!))
        XCTAssertFalse(alone.contains(IPv4Address("192.168.1.30")!))
    }

    /// This Mac's networks hold every address it would publish as a sharer, and the loopback address, so two copies on
    /// one Mac dial each other's published addresses.
    func testThisMacsNetworksHoldWhatItPublishesAndLoopback() {
        let networks = IPv4Subnet.local()
        for address in Advertiser.localIPv4Addresses() {
            XCTAssertTrue(networks.contains { $0.contains(address) }, "\(address) is on none of \(networks)")
        }
        XCTAssertTrue(networks.contains { $0.contains(IPv4Address("127.0.0.1")!) })
    }

    /// Live: the advertiser publishes the port its listener got and this Mac's addresses, and a browser hands both on.
    func testABrowsedSharerCarriesTheAddressesAndPortItListensOn() async throws {
        let name = "Published \(UInt32.random(in: 0..<1_000_000))"
        let advertiser = try Advertiser(name: name, code: "1234", hello: hello(.share, name: name))
        let port = try await advertiser.start()
        defer { advertiser.stop() }
        let browser = Browser()
        browser.start()
        defer { browser.stop() }
        let list = await firstList(from: browser, within: 10) { list in list.contains { $0.name == name && $0.port != nil } }
        let found = try XCTUnwrap(list?.first { $0.name == name }, "the advertiser should be found with its port within 10 s")
        XCTAssertEqual(found.port, port)
        XCTAssertEqual(found.addresses, Array(Advertiser.localIPv4Addresses().prefix(Advertiser.maxPublishedAddresses)),
                       "at most four go in the TXT record")

        // A wrong code through what discovery found (this Mac's Wi-Fi or Ethernet address, when it has one) comes back
        // as a wrong code at once, after one handshake on the sharer.
        let attempts = Task { () -> Int in var n = 0; for await _ in advertiser.incoming { n += 1 }; return n }
        let session = LinkSession(peer: found, code: "0000", hello: hello(.view, name: "Viewer"))
        let deadline = Task { try await Task.sleep(for: .seconds(15)); session.close() }
        session.start()
        var seen: [LinkSession.State] = []
        for await s in session.states { seen.append(s) }
        deadline.cancel()
        XCTAssertEqual(seen, [.connecting(attempt: 1), .codeRejected])
        try await Task.sleep(for: .milliseconds(200))
        advertiser.stop()
        let tried = await attempts.value
        XCTAssertEqual(tried, 1, "one handshake on the sharer")
    }
}
