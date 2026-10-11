import XCTest
import Network
import os
import NitidoTestSupport
@testable import NitidoLink
@testable import NitidoCore

final class LinkSessionTests: XCTestCase {
    private func hello(_ role: Role) -> Hello { Hello(protocolVersion: protocolVersion, role: role, name: role == .share ? "Sharer" : "Viewer", pixelWidth: 0, pixelHeight: 0, scale: 2) }

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
        // One sentence that names the sharer; Network.framework's own words stay in the log.
        XCTAssertEqual(seen.last, .closed("Sharer is no longer sharing."))
    }

    /// The sharer as discovery describes it: a Bonjour service that never resolves, and the loopback address on `port`.
    private func discovered(port: UInt16, service: NWEndpoint) -> Peer {
        Peer(id: "sharer", name: "Sharer", keyName: "Sharer", endpoint: service, addresses: [IPv4Address("127.0.0.1")!], port: port)
    }

    /// A sharer that dies and comes back with another code (a new one every launch) listens on another port: its listener
    /// binds a new one on every launch and after every rotation. Discovery publishes it, every reconnect dials what
    /// discovery says then (`currentPeer`), and the sharer turns the attempt away in the handshake. The session ends and
    /// asks for the code instead of retrying forever: one failed handshake on the sharer, not one every few seconds,
    /// three of which would rotate its code under whoever is typing it.
    func testSessionEndsWhenTheSharerComesBackWithAnotherCode() async throws {
        let first = try Advertiser(name: "Sharer", code: "1234", hello: hello(.share))
        let firstPort = try await first.start()
        let service = absentService()
        let discovery = OSAllocatedUnfairLock(initialState: discovered(port: firstPort, service: service))
        let session = LinkSession(peer: discovery.withLock { $0 }, code: "1234", hello: hello(.view), connectTimeout: 8,
                                  waitingTimeout: 5, unreachableAfter: 4, currentPeer: { discovery.withLock { $0 } })
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
        // The sharer dies without bye and comes back with a new code on another port, which discovery reports.
        let relaunched = try Advertiser(name: "Sharer", code: "5678", hello: hello(.share))
        let newPort = try await relaunched.start()
        XCTAssertNotEqual(newPort, firstPort)
        let attempts = Task { () -> Int in var held: [Link] = []; for await l in relaunched.incoming { held.append(l) }; return held.count }
        let moved = discovered(port: newPort, service: service)
        discovery.withLock { $0 = moved }
        dropped.abort(); first.stop()
        let seen = await watcher.value
        deadline.cancel()
        XCTAssertEqual(seen.last, .closed("The code on Sharer has changed. Enter the new code to connect again."))
        XCTAssertTrue(seen.contains { if case .reconnecting(1, _) = $0 { return true }; return false })
        try await Task.sleep(for: .seconds(2))           // longer than the next backoff: nothing tries again
        relaunched.stop()
        let tried = await attempts.value
        XCTAssertEqual(tried, 1, "the sharer sees one failed handshake")
    }

    /// The same, before discovery has caught up: every published address refuses the reconnect, so the sharer's listener
    /// has moved (a rotation or a relaunch, and both change the code) or is gone. The session does not dial the Bonjour
    /// service, which between two Macs fails three or four handshakes per attempt on the sharer and so rotates the code
    /// under whoever is typing it; it shows Reconnecting and fails no handshake there. Once discovery reports the new
    /// port, the next attempt reaches the sharer and ends the session after one handshake.
    func testAReconnectThatEveryPublishedAddressRefusesWaitsForDiscoveryRatherThanTheBonjourService() async throws {
        let first = try Advertiser(name: "Sharer", code: "1234", hello: hello(.share))
        let firstPort = try await first.start()
        let service = absentService()
        let discovery = OSAllocatedUnfairLock(initialState: discovered(port: firstPort, service: service))
        let mark = LogMark()
        let session = LinkSession(peer: discovery.withLock { $0 }, code: "1234", hello: hello(.view), connectTimeout: 8,
                                  waitingTimeout: 5, unreachableAfter: 4, currentPeer: { discovery.withLock { $0 } })
        let watcher = Task { () -> [LinkSession.State] in
            var seen: [LinkSession.State] = []
            for await s in session.states { seen.append(s) }
            return seen
        }
        let deadline = Task { try await Task.sleep(for: .seconds(20)); session.close() }
        session.start()
        var incoming = first.incoming.makeAsyncIterator()
        guard let dropped = await incoming.next() else { return XCTFail("no connection") }
        for await s in dropped.states { if s == .ready { break } }
        let relaunched = try Advertiser(name: "Sharer", code: "5678", hello: hello(.share))
        let newPort = try await relaunched.start()
        let attempts = Task { () -> Int in var held: [Link] = []; for await l in relaunched.incoming { held.append(l) }; return held.count }
        dropped.abort(); first.stop()                    // discovery still says the old port

        try await Task.sleep(for: .seconds(2.5))         // three reconnects at 0.5, 1 and 2 s
        let tried = try mark.entries("session").map(\.composedMessage).filter { $0.hasPrefix("trying ") }
        XCTAssertFalse(tried.isEmpty)
        XCTAssertTrue(tried.allSatisfy { $0 == "trying 127.0.0.1:\(firstPort) (route 1 of 2)" }, "never the Bonjour service: \(tried)")
        XCTAssertGreaterThanOrEqual(tried.count, 3, "the session goes on reconnecting: \(tried)")

        let moved = discovered(port: newPort, service: service)
        discovery.withLock { $0 = moved }
        let seen = await watcher.value
        deadline.cancel()
        XCTAssertEqual(seen.last, .closed("The code on Sharer has changed. Enter the new code to connect again."))
        try await Task.sleep(for: .milliseconds(500))
        relaunched.stop()
        let reached = await attempts.value
        XCTAssertEqual(reached, 1, "one handshake on the sharer, once discovery said where it is")
    }

    /// A sharer that was force-quit, crashed or shut down: every published address refuses the reconnects, and discovery
    /// no longer lists it. After the grace the sharer itself gives a dropped viewer, the session ends saying so, instead
    /// of showing Reconnecting for ever (a relaunched sharer has a new code, so no reconnect could pass by itself). While
    /// discovery still lists it, the session keeps waiting for what discovery says next.
    func testASharerGoneFromDiscoveryWhoseAddressesKeepRefusingEndsTheSession() async throws {
        for listed in [false, true] {
            let first = try Advertiser(name: "Sharer", code: "1234", hello: hello(.share))
            let firstPort = try await first.start()
            let peer = discovered(port: firstPort, service: absentService())
            let session = LinkSession(peer: peer, code: "1234", hello: hello(.view), connectTimeout: 8, waitingTimeout: 5,
                                      unreachableAfter: 4, currentPeer: { peer }, isListed: { listed }, goneAfter: 2)
            let watcher = Task { () -> [LinkSession.State] in
                var seen: [LinkSession.State] = []
                for await s in session.states { seen.append(s) }
                return seen
            }
            session.start()
            var incoming = first.incoming.makeAsyncIterator()
            guard let dropped = await incoming.next() else { return XCTFail("no connection") }
            for await s in dropped.states { if s == .ready { break } }
            dropped.abort(); first.stop()   // gone: nothing listens on its port any more
            try await Task.sleep(for: .seconds(6))
            session.close()
            let seen = await watcher.value
            if listed {
                XCTAssertTrue(seen.contains { if case .reconnecting = $0 { true } else { false } })
                XCTAssertEqual(seen.last, .closed(nil), "still listed: it goes on waiting until the person leaves")
            } else {
                XCTAssertEqual(seen.filter { if case .closed = $0 { true } else { false } }, [.closed("Sharer is no longer sharing.")],
                               "gone from discovery and refusing for the grace: \(seen)")
            }
        }
    }

    /// Spec 12: a protocol mismatch is final and names both versions. The two sides exchange hellos once TLS is up, and
    /// a link is ready only when they match, so a sharer on another version is never shown as connected, and the
    /// session ends as `.incompatible` with the sharer's version instead of reconnecting every 5 s forever.
    func testASharerOnAnotherProtocolVersionEndsTheSessionAsIncompatible() async throws {
        let newer = Hello(protocolVersion: protocolVersion + 1, role: .share, name: "Sharer", pixelWidth: 0, pixelHeight: 0, scale: 2)
        let advertiser = try Advertiser(name: "Sharer", code: "1234", hello: newer)
        let port = try await advertiser.start()
        defer { advertiser.stop() }
        let session = LinkSession(endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!), code: "1234",
                                  sharerName: "Sharer", hello: hello(.view))
        let seen = await states(of: session, within: 15)
        XCTAssertEqual(seen, [.connecting(attempt: 1), .incompatible(peerVersion: protocolVersion + 1)])
    }

    /// The same from the other side: a viewer on a newer version than the sharer ends as `.incompatible` with the
    /// sharer's version, and neither side reconnects.
    func testAViewerOnAnotherProtocolVersionEndsTheSessionAsIncompatible() async throws {
        let advertiser = try Advertiser(name: "Sharer", code: "1234", hello: hello(.share))
        let port = try await advertiser.start()
        defer { advertiser.stop() }
        let newer = Hello(protocolVersion: protocolVersion + 1, role: .view, name: "Viewer", pixelWidth: 0, pixelHeight: 0, scale: 2)
        let session = LinkSession(endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!), code: "1234",
                                  sharerName: "Sharer", hello: newer)
        let seen = await states(of: session, within: 15)
        XCTAssertEqual(seen, [.connecting(attempt: 1), .incompatible(peerVersion: protocolVersion)])
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

    /// Two Macs, wrong code: through the Bonjour service the handshake failed four times on the sharer (most likely
    /// Network.framework trying each address it resolved), nothing came back and the viewer gave up after 15 s with "No
    /// answer". Through
    /// the address the sharer published, the failed handshake comes back at once and the session ends as a wrong code,
    /// after one handshake on the sharer. The right code pairs the same way.
    func testAWrongCodeThroughThePublishedAddressIsRejectedAtOnce() async throws {
        let advertiser = try Advertiser(name: "Sharer", code: "1234", hello: hello(.share))
        let port = try await advertiser.start()
        // Held, as the share holds them (`ShareModel.unpaired`): the sharer's end sends the hello a link is ready on.
        let attempts = Task { () -> Int in var held: [Link] = []; for await l in advertiser.incoming { held.append(l) }; return held.count }
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

    /// A published address that never takes the connection (a stale address, a host that drops the packets) hands over
    /// to the next route once TCP gives up on it: the route's limit is TCP's connection timeout, in whole seconds.
    /// 192.0.2.1 is a documentation address that no host answers.
    func testAPublishedAddressThatNeverTakesTheConnectionFallsBackAfterItsLimit() async throws {
        let advertiser = try Advertiser(name: "Sharer", code: "1234", hello: hello(.share))
        let port = try await advertiser.start()
        defer { advertiser.stop() }
        let sharer = Peer(id: "stale", name: "Sharer", keyName: "Sharer",
                          endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!),
                          addresses: [IPv4Address("192.0.2.1")!], port: 47_219)
        let session = LinkSession(peer: sharer, code: "1234", hello: hello(.view), connectTimeout: 8, waitingTimeout: 5,
                                  unreachableAfter: 1, subnets: { [] })
        let clock = ContinuousClock(), started = clock.now
        let watcher = Task { () -> [LinkSession.State] in
            var seen: [LinkSession.State] = []
            for await s in session.states { seen.append(s); if s == .ready { break } }
            return seen
        }
        session.start()
        let seen = await watcher.value
        XCTAssertEqual(seen, [.connecting(attempt: 1), .ready])
        XCTAssertLessThan(clock.now - started, .seconds(3), "within the route's second, and the handshake after it")
        session.close()
    }

    /// The published address takes the connection and then says nothing: TCP is up, so the sharer may be checking a
    /// handshake there, and cutting it at the route's limit to try another route could count a second wrong code for
    /// one typed (a slow first ARP to a sleeping Mac can put the handshake right at the limit). Only TCP's setup has the
    /// route's limit; the handshake has what is left of the attempt, and its silence is the attempt's answer.
    func testAPublishedAddressThatTakesTheConnectionAndStallsIsTheAttemptsAnswer() async throws {
        let silent = try SilentListener()
        let silentPort = try await silent.start()
        defer { silent.stop() }
        let next = try SilentListener()
        let nextPort = try await next.start()
        defer { next.stop() }
        let sharer = Peer(id: "silent", name: "Sharer", keyName: "Sharer",
                          endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: nextPort)!),
                          addresses: [IPv4Address("127.0.0.1")!], port: silentPort)
        let session = LinkSession(peer: sharer, code: "1234", hello: hello(.view), connectTimeout: 3, waitingTimeout: 5, unreachableAfter: 1)
        let clock = ContinuousClock(), started = clock.now
        let seen = await states(of: session, within: 10)
        let took = clock.now - started
        XCTAssertEqual(seen, [.connecting(attempt: 1), .closed("Sharer did not answer within 3 seconds.")])
        XCTAssertGreaterThanOrEqual(took, .milliseconds(2_900), "the handshake had the attempt's whole deadline")
        XCTAssertEqual(silent.accepted, 1)
        XCTAssertEqual(next.accepted, 0, "the next route was not tried")
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
        XCTAssertEqual(seen.last, .closed("Sharer closed the connection."))
        XCTAssertEqual(resetting.accepted, 1, "one connection on the address that reset it")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(next.accepted, 0, "the next route was not tried")
    }

    /// A session to `sharer` from a viewer on `networks`: its states until it is ready (or ends, 15 s at most), how long
    /// that took, and what it logged.
    private func pair(_ sharer: Peer, on networks: [IPv4Subnet]) async throws -> (seen: [LinkSession.State], took: Duration, log: [String]) {
        let mark = LogMark()
        let session = LinkSession(peer: sharer, code: "1234", hello: hello(.view), connectTimeout: 8, waitingTimeout: 5,
                                  unreachableAfter: 4, subnets: { networks })
        let clock = ContinuousClock(), started = clock.now
        let watcher = Task { () -> [LinkSession.State] in
            var seen: [LinkSession.State] = []
            for await s in session.states { seen.append(s); if s == .ready { break } }
            return seen
        }
        let deadline = Task { try await Task.sleep(for: .seconds(15)); session.close() }
        session.start()
        let seen = await watcher.value
        let took = clock.now - started
        deadline.cancel()
        session.close()
        return (seen, took, try mark.entries("session").map(\.composedMessage))
    }

    /// A published address on one of the viewer's networks is dialled before one on none of them, so the attempt does not
    /// spend 4 s on the address elsewhere first. 192.0.2.1 (a documentation address, on no network) stands for a desktop
    /// Mac's Ethernet on another network, published first; the viewer's networks are given (loopback only).
    func testAPublishedAddressOnTheViewersNetworkIsDialledBeforeOneElsewhere() async throws {
        let advertiser = try Advertiser(name: "Sharer", code: "1234", hello: hello(.share))
        let port = try await advertiser.start()
        defer { advertiser.stop() }
        let sharer = Peer(id: "elsewhere", name: "Sharer", keyName: "Sharer", endpoint: absentService(),
                          addresses: [IPv4Address("192.0.2.1")!, IPv4Address("127.0.0.1")!], port: port)
        let loopback = IPv4Subnet(address: IPv4Address("127.0.0.1")!, mask: IPv4Address("255.0.0.0")!)
        let (seen, took, lines) = try await pair(sharer, on: [loopback])
        XCTAssertEqual(seen, [.connecting(attempt: 1), .ready])
        XCTAssertLessThan(took, .seconds(2), "no time spent on the address elsewhere")
        let tried = lines.filter { $0.hasPrefix("trying ") }
        XCTAssertEqual(tried, ["trying 127.0.0.1:\(port) (route 1 of 3)"], "\(lines)")
        XCTAssertTrue(lines.contains("dialling 192.0.2.1 last of the published addresses: on none of this Mac's networks"), "\(lines)")
    }

    /// A published address on none of the viewer's networks is still dialled, before the Bonjour service: a sharer on
    /// another VLAN behind an mDNS reflector, or one with only a self-assigned 169.254 address, is reached that way. Here
    /// the viewer's networks are given without loopback and the Bonjour service never resolves, so only the published
    /// 127.0.0.1 can pair.
    func testAPublishedAddressOnNoneOfTheViewersNetworksIsDialledWhenItIsTheOnlyOne() async throws {
        let advertiser = try Advertiser(name: "Sharer", code: "1234", hello: hello(.share))
        let port = try await advertiser.start()
        defer { advertiser.stop() }
        let sharer = Peer(id: "reflected", name: "Sharer", keyName: "Sharer", endpoint: absentService(),
                          addresses: [IPv4Address("127.0.0.1")!], port: port)
        let elsewhere = IPv4Subnet(address: IPv4Address("192.168.77.2")!, mask: IPv4Address("255.255.255.0")!)
        let (seen, took, lines) = try await pair(sharer, on: [elsewhere])
        XCTAssertEqual(seen, [.connecting(attempt: 1), .ready], "\(lines)")
        XCTAssertLessThan(took, .seconds(2))
        let tried = lines.filter { $0.hasPrefix("trying ") }
        XCTAssertEqual(tried, ["trying 127.0.0.1:\(port) (route 1 of 2)"], "\(lines)")
        XCTAssertTrue(lines.contains("dialling 127.0.0.1 last of the published addresses: on none of this Mac's networks"), "\(lines)")
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
        XCTAssertEqual(seen, [.connecting(attempt: 1), .closed("Sharer did not answer within 8 seconds.")])
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
