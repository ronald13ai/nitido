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

    /// A browser can run without peer-to-peer Wi-Fi, and switch: a new browser replaces the running one (an `NWBrowser`'s
    /// parameters cannot change), and the list goes on with what it finds.
    func testABrowserSwitchesPeerToPeerWiFiOffAndOnAndKeepsFinding() async throws {
        let browser = Browser(peerToPeer: false)
        XCTAssertFalse(browser.includesPeerToPeerForTesting)
        browser.start()
        defer { browser.stop() }
        browser.usePeerToPeer(true)
        XCTAssertTrue(browser.includesPeerToPeerForTesting)
        browser.usePeerToPeer(false)
        XCTAssertFalse(browser.includesPeerToPeerForTesting)
        let name = "Switch \(UInt32.random(in: 0..<1_000_000))"
        let advertiser = try Advertiser(name: name, code: "1234", hello: hello(.share, name: name))
        _ = try await advertiser.start()
        defer { advertiser.stop() }
        let found = await firstList(from: browser, within: 10) { $0.contains { $0.name == name } }
        XCTAssertNotNil(found, "the browser that replaced the first one finds a sharer")
        let unstarted = Browser()
        unstarted.usePeerToPeer(false)
        XCTAssertTrue(unstarted.includesPeerToPeerForTesting, "nothing switches before start")
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
    /// address instead of the Bonjour service, which Network.framework most likely resolves to several addresses and
    /// tries one after another. A record from a sharer that publishes none (an older build) still gives a peer, with no
    /// address.
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

    private func route(_ address: String) -> NWEndpoint { .hostPort(host: .ipv4(IPv4Address(address)!), port: 50_000) }

    /// The published addresses on one of the viewer's own networks are dialled first, then the others, then the Bonjour
    /// service; two addresses at most. A desktop Mac whose Ethernet is on another network publishes that address first:
    /// dialled first, its silence would cost 4 s before the Wi-Fi address that works. An address on none of the viewer's
    /// networks is still dialled, after those: a sharer on another VLAN behind an mDNS reflector may be reached that way.
    func testPublishedAddressesOnTheViewersNetworksComeFirstThenTheOthersThenTheService() {
        let service = NWEndpoint.service(name: "Sharer", type: "_nitido._tcp", domain: "local.", interface: nil)
        let wifi = subnet("192.168.1.31", "255.255.255.0")
        let desktop = Peer(id: "s", name: "Sharer", keyName: "Sharer", endpoint: service,
                           addresses: ["10.20.0.7", "192.168.1.20", "169.254.10.1"].map { IPv4Address($0)! }, port: 50_000)
        XCTAssertEqual(desktop.routes(on: [wifi]), [route("192.168.1.20"), route("10.20.0.7"), service],
                       "the address on the viewer's network first, the one elsewhere next, the Bonjour service last")
        XCTAssertEqual(desktop.routes(on: [subnet("169.254.80.2", "255.255.0.0"), wifi]),
                       [route("192.168.1.20"), route("169.254.10.1"), service],
                       "two on the viewer's networks, in the order the sharer published them")
        XCTAssertEqual(desktop.routes(on: [subnet("172.20.4.9", "255.255.0.0")]), [route("10.20.0.7"), route("192.168.1.20"), service],
                       "on none of the viewer's networks: still dialled, in the order the sharer published them")
        XCTAssertEqual(desktop.routes(on: []), [route("10.20.0.7"), route("192.168.1.20"), service])
        let twoOnWifi = Peer(id: "s", name: "Sharer", keyName: "Sharer", endpoint: service,
                             addresses: ["10.20.0.7", "192.168.1.20", "192.168.1.21", "169.254.10.1"].map { IPv4Address($0)! },
                             port: 50_000)
        XCTAssertEqual(twoOnWifi.routes(on: [wifi]), [route("192.168.1.20"), route("192.168.1.21"), service],
                       "two on the viewer's network take both tries")
    }

    /// A sharer whose only address is self-assigned (no DHCP server), seen by a viewer with no such address: the address
    /// is on none of the viewer's networks and still dialled, before the Bonjour service.
    func testAnAddressOnNoneOfTheViewersNetworksIsDialledWhenItIsTheOnlyOne() {
        let service = NWEndpoint.service(name: "Sharer", type: "_nitido._tcp", domain: "local.", interface: nil)
        let selfAssigned = Peer(id: "s", name: "Sharer", keyName: "Sharer", endpoint: service,
                                addresses: [IPv4Address("169.254.10.1")!], port: 50_000)
        XCTAssertEqual(selfAssigned.routes(on: [subnet("192.168.1.31", "255.255.255.0")]), [route("169.254.10.1"), service])
        XCTAssertEqual(selfAssigned.routes(on: []), [route("169.254.10.1"), service])
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

    /// `getifaddrs` hands netmasks over trimmed: `sa_len` 5 for 255.0.0.0 (lo0), 7 for 255.255.255.0 (en0), the bytes past
    /// it not part of the address. They are read no further than that length, the rest taken as zero, whatever follows
    /// in memory.
    func testATrimmedNetmaskIsReadNoFurtherThanItsLength() {
        func read(_ bytes: [UInt8]) -> IPv4Address? {
            var buffer = bytes + [UInt8](repeating: 0xAB, count: 16 - bytes.count)
            return buffer.withUnsafeMutableBytes { IPv4Interface.ipv4($0.baseAddress!.assumingMemoryBound(to: sockaddr.self)) }
        }
        let inet = UInt8(AF_INET)
        XCTAssertEqual(read([5, inet, 0, 0, 255]), IPv4Address("255.0.0.0"))
        XCTAssertEqual(read([7, inet, 0, 0, 255, 255, 255]), IPv4Address("255.255.255.0"))
        XCTAssertEqual(read([16, inet, 0, 0, 192, 168, 1, 3, 0, 0, 0, 0, 0, 0, 0, 0]), IPv4Address("192.168.1.3"))
        XCTAssertEqual(read([0, inet]), IPv4Address("0.0.0.0"), "a mask of no bits")
        XCTAssertNil(read([16, UInt8(AF_INET6)]))
    }

    /// This Mac's networks are those of the addresses it publishes: loopback is not one, since no published address is
    /// ever on it.
    func testThisMacsNetworksHoldWhatItPublishes() {
        let networks = IPv4Subnet.local()
        for address in Advertiser.localIPv4Addresses() {
            XCTAssertTrue(networks.contains { $0.contains(address) }, "\(address) is on none of \(networks)")
        }
        XCTAssertFalse(networks.contains { $0.contains(IPv4Address("127.0.0.1")!) })
    }

    /// A sharer whose addresses change mid-share (a new DHCP lease, another network) publishes the new ones, on the port
    /// its listener is ready on, so a viewer does not spend up to 4 s on an address this Mac no longer has. The same
    /// addresses again change nothing.
    func testAnAdvertiserPublishesItsAddressesAgainWhenTheyChange() async throws {
        let advertiser = try Advertiser(name: "Moving", code: "1234", hello: hello(.share, name: "Moving"))
        let port = try await advertiser.start()
        defer { advertiser.stop() }
        let moved = [IPv4Address("192.0.2.7")!, IPv4Address("198.51.100.3")!]
        let txt = try XCTUnwrap(advertiser.republishForTesting(addresses: moved))
        XCTAssertEqual(txt["addrs"], "192.0.2.7,198.51.100.3")
        XCTAssertEqual(txt["port"], "\(port)")
        XCTAssertEqual(txt["name"], "Moving")
        let again = try XCTUnwrap(advertiser.republishForTesting(addresses: moved))
        XCTAssertEqual(again["addrs"], "192.0.2.7,198.51.100.3")
        let none = try XCTUnwrap(advertiser.republishForTesting(addresses: []))
        XCTAssertNil(none["addrs"], "no IPv4 address left: none published")
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
