import XCTest
import Network
@testable import NitidoLink
@testable import NitidoCore

final class LinkSessionTests: XCTestCase {
    private func hello(_ role: Role) -> Hello { Hello(protocolVersion: protocolVersion, role: role, name: role == .share ? "Sharer" : "Viewer", pixelWidth: 0, pixelHeight: 0, scale: 2) }

    func testSessionReconnectsAfterTheSharerDropsWithoutBye() async throws {
        let advertiser = try Advertiser(name: "Sharer", code: "1234", hello: hello(.share), port: 47_211)
        _ = try await advertiser.start()
        let session = LinkSession(endpoint: .hostPort(host: "127.0.0.1", port: 47_211), code: "1234", sharerName: "Sharer", hello: hello(.view))
        session.start()
        var incoming = advertiser.incoming.makeAsyncIterator()
        guard let first = await incoming.next() else { return XCTFail() }

        // The watcher owns the list and hands it back: Swift 6 rejects a task mutating a captured `var`.
        let watcher = Task { () -> [LinkSession.State] in
            var seen: [LinkSession.State] = []
            for await s in session.states {
                seen.append(s)
                if seen.filter({ $0 == .ready }).count == 2 { break }
            }
            return seen
        }
        for await s in first.states { if s == .ready { break } }
        try await Task.sleep(for: .milliseconds(200))
        first.abort()                                    // simulate a network drop: no bye
        guard let second = await incoming.next() else { return XCTFail("no reconnect") }
        for await s in second.states { if s == .ready { break } }
        let seen = await watcher.value
        XCTAssertEqual(seen.first, .connecting(attempt: 1))
        XCTAssertTrue(seen.contains { if case .reconnecting(let a, let d) = $0 { return a == 1 && d == 0.5 }; return false })
        XCTAssertEqual(seen.filter { $0 == .ready }.count, 2)
        session.close(); advertiser.stop()
    }

    func testSessionDoesNotRetryWhenTheFirstHandshakeFails() async throws {
        let advertiser = try Advertiser(name: "Sharer", code: "1234", hello: hello(.share), port: 47_212)
        _ = try await advertiser.start()
        let session = LinkSession(endpoint: .hostPort(host: "127.0.0.1", port: 47_212), code: "0000", sharerName: "Sharer", hello: hello(.view))
        session.start()
        var closed: String?
        for await s in session.states { if case .closed(let reason) = s { closed = reason; break } }
        XCTAssertNotNil(closed)
        advertiser.stop()
    }

    func testSilenceForThreeSecondsFailsTheLink() async throws {
        let advertiser = try Advertiser(name: "Sharer", code: "1234", hello: hello(.share), port: 47_213)
        _ = try await advertiser.start()
        let viewer = Link.connect(to: .hostPort(host: "127.0.0.1", port: 47_213), code: "1234", sharerName: "Sharer", hello: hello(.view))
        var incoming = advertiser.incoming.makeAsyncIterator()
        guard let sharer = await incoming.next() else { return XCTFail() }
        for await s in sharer.states { if s == .ready { break } }
        sharer.muteForTesting()                          // stops answering pings without closing the socket
        var failed = false
        for await s in viewer.states { if case .failed = s { failed = true; break }; if s == .cancelled { break } }
        XCTAssertTrue(failed)
        advertiser.stop()
    }
}
