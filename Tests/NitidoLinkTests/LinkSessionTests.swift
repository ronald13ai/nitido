import XCTest
import Network
import NitidoTestSupport
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

    /// A Bonjour service that never resolves: a session that tried it would wait for its deadline, so one that ends at
    /// once went another way.
    private func absentService() -> NWEndpoint {
        .service(name: "Absent \(UInt32.random(in: 0..<1_000_000))", type: "_nitido._tcp", domain: "local.", interface: nil)
    }

    private func states(of session: LinkSession, within seconds: Double) async -> [LinkSession.State] {
        let deadline = Task { try await Task.sleep(for: .seconds(seconds)); session.close() }
        session.start()
        var seen: [LinkSession.State] = []
        for await s in session.states { seen.append(s) }
        deadline.cancel()
        return seen
    }

    /// Two Macs, wrong code: through the Bonjour service Network.framework tried the handshake on each address it
    /// resolved, failed it on every one, reported nothing and the viewer gave up after 15 s with "No answer". Through
    /// the address the sharer published, the failed handshake comes back at once and the session ends as a wrong code,
    /// after one handshake on the sharer. The right code pairs the same way.
    func testAWrongCodeThroughThePublishedAddressIsRejectedAtOnce() async throws {
        let advertiser = try Advertiser(name: "Sharer", code: "1234", hello: hello(.share))
        let port = try await advertiser.start()
        let attempts = Task { () -> Int in var n = 0; for await _ in advertiser.incoming { n += 1 }; return n }
        let sharer = Peer(id: "published", name: "Sharer", keyName: "Sharer", endpoint: absentService(),
                          addresses: [IPv4Address("127.0.0.1")!], port: port)
        let clock = ContinuousClock(), started = clock.now
        let wrong = LinkSession(peer: sharer, code: "0000", hello: hello(.view))
        let seen = await states(of: wrong, within: 15)
        XCTAssertEqual(seen, [.connecting(attempt: 1), .codeRejected])
        XCTAssertLessThan(clock.now - started, .seconds(2), "the failed handshake came back at once")

        let right = LinkSession(peer: sharer, code: "1234", hello: hello(.view))
        let watcher = Task { () -> Bool in for await s in right.states where s == .ready { return true }; return false }
        right.start()
        let ready = await watcher.value
        XCTAssertTrue(ready, "the right code pairs through the published address")
        XCTAssertEqual(right.includesPeerToPeerForTesting, false, "a published address is reached on the network it is on, not over AWDL")
        right.close()
        try await Task.sleep(for: .milliseconds(200))
        advertiser.stop()
        let tried = await attempts.value
        XCTAssertEqual(tried, 2, "one connection per attempt reached the sharer")
    }

    /// The published address refuses (a port the sharer no longer listens on): the next route is tried at once, without
    /// the five seconds a refusal on the last route waits for.
    func testARefusedPublishedAddressFallsBackAtOnce() async throws {
        let advertiser = try Advertiser(name: "Sharer", code: "1234", hello: hello(.share))
        let port = try await advertiser.start()
        let sharer = Peer(id: "stale", name: "Sharer", keyName: "Sharer",
                          endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!),
                          addresses: [IPv4Address("127.0.0.1")!], port: 1)
        let session = LinkSession(peer: sharer, code: "1234", hello: hello(.view))
        let clock = ContinuousClock(), started = clock.now
        let watcher = Task { () -> [LinkSession.State] in
            var seen: [LinkSession.State] = []
            for await s in session.states { seen.append(s); if s == .ready { break } }
            return seen
        }
        session.start()
        let seen = await watcher.value
        XCTAssertEqual(seen, [.connecting(attempt: 1), .ready], "one attempt, two routes")
        XCTAssertLessThan(clock.now - started, .seconds(2))
        session.close(); advertiser.stop()
    }

    /// The published address takes the connection and never answers (a stale address, a host that drops the packets):
    /// after `unreachableAfter` with no answer the next route is tried.
    func testAPublishedAddressThatNeverAnswersFallsBackAfterItsLimit() async throws {
        let silent = try SilentListener()
        let silentPort = try await silent.start()
        defer { silent.stop() }
        let advertiser = try Advertiser(name: "Sharer", code: "1234", hello: hello(.share))
        let port = try await advertiser.start()
        defer { advertiser.stop() }
        let sharer = Peer(id: "silent", name: "Sharer", keyName: "Sharer",
                          endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!),
                          addresses: [IPv4Address("127.0.0.1")!], port: silentPort)
        let session = LinkSession(peer: sharer, code: "1234", hello: hello(.view), connectTimeout: 8, waitingTimeout: 5, unreachableAfter: 0.5)
        let clock = ContinuousClock(), started = clock.now
        let watcher = Task { () -> [LinkSession.State] in
            var seen: [LinkSession.State] = []
            for await s in session.states { seen.append(s); if s == .ready { break } }
            return seen
        }
        session.start()
        let seen = await watcher.value
        let took = clock.now - started
        XCTAssertEqual(seen, [.connecting(attempt: 1), .ready])
        XCTAssertGreaterThanOrEqual(took, .milliseconds(450), "the silent address had its half second")
        XCTAssertLessThan(took, .seconds(3))
        XCTAssertEqual(silent.accepted, 1)
        session.close()
    }

    /// The published address takes the connection and resets it: the sharer was reached and may already have failed a
    /// handshake on the keys, so trying the next route would make a second one there, another wrong code for one typed.
    /// Only an error that says the address has no path to the sharer hands over to the next route; this one ends the
    /// attempt with its reason, after one connection, and the next route is never tried.
    func testAPublishedAddressThatResetsTheConnectionEndsTheAttempt() async throws {
        let resetting = try ResettingListener()
        let resettingPort = resetting.start()
        defer { resetting.stop() }
        let next = try SilentListener()
        let nextPort = try await next.start()
        defer { next.stop() }
        let sharer = Peer(id: "reset", name: "Sharer", keyName: "Sharer",
                          endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: nextPort)!),
                          addresses: [IPv4Address("127.0.0.1")!], port: resettingPort)
        let session = LinkSession(peer: sharer, code: "1234", hello: hello(.view))
        let clock = ContinuousClock(), started = clock.now
        let seen = await states(of: session, within: 15)
        XCTAssertLessThan(clock.now - started, .seconds(3), "the reset ended the attempt at once")
        XCTAssertEqual(seen.count, 2, "one attempt, then the end: \(seen)")
        XCTAssertFalse(seen.contains(.codeRejected), "a reset is not a wrong code")
        guard case .closed(let reason?)? = seen.last else { return XCTFail("expected .closed with a reason, got \(seen)") }
        XCTAssertTrue(reason.hasPrefix("Could not connect to Sharer."), reason)
        XCTAssertEqual(resetting.accepted, 1, "one connection on the address that reset it")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(next.accepted, 0, "the next route was not tried")
    }

    /// One attempt gives up after 8 seconds over all its routes (15 before): "No answer" says so.
    func testAnAttemptGivesUpAfterEightSeconds() async throws {
        let silent = try SilentListener()
        let port = try await silent.start()
        defer { silent.stop() }
        let session = LinkSession(endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!), code: "1234",
                                  sharerName: "Sharer", hello: hello(.view))
        let clock = ContinuousClock(), started = clock.now
        let seen = await states(of: session, within: 20)
        let took = clock.now - started
        XCTAssertEqual(seen, [.connecting(attempt: 1), .closed("Could not connect to Sharer. No answer from the other Mac within 8 seconds.")])
        XCTAssertGreaterThanOrEqual(took, .milliseconds(7_900))
        XCTAssertLessThan(took, .seconds(10))
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
