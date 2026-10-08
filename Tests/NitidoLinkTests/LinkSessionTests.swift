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
        let mark = LogMark()
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

        // The drop is in the log with its reason, not '<private>': the log is the failure record (spec 12).
        let drops = try mark.entries("session").filter { $0.composedMessage.hasPrefix("link failed (") }
        XCTAssertFalse(drops.isEmpty, "the drop was not logged")
        XCTAssertEqual(drops.flatMap(\.redactedStrings), [], "Console shows these as <private>")
    }

    /// A wrong code fails the first handshake on the keys: the session ends as `.codeRejected` (the viewer's "Wrong
    /// code"), not as `.closed`, and does not retry.
    func testSessionDoesNotRetryWhenTheFirstHandshakeFails() async throws {
        let advertiser = try Advertiser(name: "Sharer", code: "1234", hello: hello(.share), port: 47_212)
        _ = try await advertiser.start()
        let session = LinkSession(endpoint: .hostPort(host: "127.0.0.1", port: 47_212), code: "0000", sharerName: "Sharer", hello: hello(.view))
        // Bounded: a session that kept retrying would never end its states.
        let deadline = Task { try await Task.sleep(for: .seconds(15)); session.close() }
        session.start()
        var seen: [LinkSession.State] = []
        for await s in session.states { seen.append(s) }
        deadline.cancel()
        XCTAssertEqual(seen, [.connecting(attempt: 1), .codeRejected])
        advertiser.stop()
    }

    /// Nothing listens there (a Mac that has just stopped sharing): the connection is refused, which says nothing about
    /// the code. The session ends as `.closed` with the reason the link gave, never as `.codeRejected`, and does not
    /// retry. Before, every first failure read "Check the code", and the viewer called a right code wrong.
    func testSessionThatCannotReachTheSharerSaysWhyInsteadOfBlamingTheCode() async throws {
        let session = LinkSession(endpoint: .hostPort(host: "127.0.0.1", port: 1), code: "1234", sharerName: "Sharer",
                                  hello: hello(.view), connectTimeout: 60, waitingTimeout: 0.5)
        let deadline = Task { try await Task.sleep(for: .seconds(10)); session.close() }
        session.start()
        var seen: [LinkSession.State] = []
        for await s in session.states { seen.append(s) }
        deadline.cancel()
        XCTAssertEqual(seen.count, 2, "one attempt, then the end: \(seen)")
        XCTAssertEqual(seen.first, .connecting(attempt: 1))
        XCTAssertFalse(seen.contains(.codeRejected), "a refused connection is not a wrong code")
        guard case .closed(let reason?)? = seen.last else { return XCTFail("expected .closed with a reason, got \(seen)") }
        XCTAssertTrue(reason.hasPrefix("Could not connect to Sharer. Could not reach the other Mac"), reason)
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

    func testBackoffDoublesFromHalfASecondUpToFive() {
        XCTAssertEqual((1...6).map { LinkSession.retryDelay(attempt: $0) }, [0.5, 1, 2, 4, 5, 5])
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
