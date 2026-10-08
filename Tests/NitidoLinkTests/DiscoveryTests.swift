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
        let second = try Advertiser(name: name, code: "1234", hello: hello(.share, name: name))
        _ = try await second.start()
        defer { first.stop(); second.stop() }
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
        let second = try Advertiser(name: name, code: "1234", hello: hello(.share, name: name))
        _ = try await second.start()
        defer { first.stop(); second.stop() }

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
}
