import XCTest
import Network
@testable import NitidoLink
@testable import NitidoCore

final class LinkSessionTests: XCTestCase {
    private func hello(_ role: Role) -> Hello { Hello(protocolVersion: protocolVersion, role: role, name: role == .share ? "Sharer" : "Viewer", pixelWidth: 0, pixelHeight: 0, scale: 2) }

    /// A sharer listening on `port` again, as soon as the one stopped there has let the port go (its stop and its
    /// dropped connection finish on their own queues).
    private func relaunch(code: String, port: UInt16) async throws -> Advertiser {
        for _ in 0..<40 {
            let advertiser = try Advertiser(name: "Sharer", code: code, hello: hello(.share), port: port)
            do { _ = try await advertiser.start(); return advertiser } catch { advertiser.stop() }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw XCTSkip("port \(port) stayed in use")
    }

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

    /// A sharer that dies and comes back with another code (a new one every launch) turns the reconnect away in the
    /// handshake. The session ends and asks for the code instead of retrying forever: one failed handshake on the
    /// sharer, not one every few seconds, three of which would rotate its code under whoever is typing it.
    func testSessionEndsWhenTheSharerComesBackWithAnotherCode() async throws {
        let first = try Advertiser(name: "Sharer", code: "1234", hello: hello(.share), port: 47_214)
        _ = try await first.start()
        let session = LinkSession(endpoint: .hostPort(host: "127.0.0.1", port: 47_214), code: "1234", sharerName: "Sharer", hello: hello(.view))
        let watcher = Task { () -> [LinkSession.State] in
            var seen: [LinkSession.State] = []
            for await s in session.states { seen.append(s) }
            return seen
        }
        // Bounded: a session that kept retrying would never end its states.
        let deadline = Task { try await Task.sleep(for: .seconds(15)); session.close() }
        session.start()
        var incoming = first.incoming.makeAsyncIterator()
        guard let dropped = await incoming.next() else { return XCTFail("no connection") }
        for await s in dropped.states { if s == .ready { break } }
        dropped.abort(); first.stop()                    // the sharer dies without bye...
        let relaunched = try await relaunch(code: "5678", port: 47_214)   // ...and comes back with a new code
        let attempts = Task { () -> Int in var n = 0; for await _ in relaunched.incoming { n += 1 }; return n }
        let seen = await watcher.value
        deadline.cancel()
        XCTAssertEqual(seen.last, .closed("The code on Sharer has changed. Enter the new code to connect again."))
        XCTAssertTrue(seen.contains { if case .reconnecting(1, _) = $0 { return true }; return false })
        try await Task.sleep(for: .seconds(2))           // longer than the next backoff: nothing tries again
        relaunched.stop()
        let tried = await attempts.value
        XCTAssertEqual(tried, 1, "the sharer sees one failed handshake")
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
