import XCTest
import Network
import dnssd
import os
import NitidoTestSupport
@testable import NitidoLink
@testable import NitidoCore

/// The ways a link, a listener or discovery can fail, and that each one ends where the UI can see it.
final class LinkFailureTests: XCTestCase {
    private func hello(_ role: Role) -> Hello { Hello(protocolVersion: protocolVersion, role: role, name: role == .share ? "Sharer" : "Viewer", pixelWidth: 1920, pixelHeight: 1080, scale: 2) }

    /// Nothing listens on loopback port 1: the connection is refused and Network.framework parks it in `.waiting`.
    private let refused = NWEndpoint.hostPort(host: "127.0.0.1", port: 1)

    private enum Outcome: Equatable { case ended(last: Link.State?), timedOut }

    /// How `states` ends: the last state before the stream finished, or `.timedOut` if it is still open after `seconds`.
    private func outcome(of link: Link, within seconds: Double) async -> Outcome {
        await withTaskGroup(of: Outcome.self) { group in
            group.addTask { var last: Link.State?; for await s in link.states { last = s }; return .ended(last: last) }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)); return .timedOut }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }
    }

    private func collect<T: Sendable>(_ stream: AsyncStream<T>, within seconds: Double) async -> [T]? {
        await withTaskGroup(of: [T]?.self) { group in
            group.addTask { var all: [T] = []; for await v in stream { all.append(v) }; return Task.isCancelled ? nil : all }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    // MARK: Link

    func testCloseEndsALinkThatNeverBecameReady() async throws {
        let link = Link.connect(to: refused, code: "1234", sharerName: "Sharer", hello: hello(.view), connectTimeout: 60, waitingTimeout: 60)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(link.state, .connecting)
        link.close()
        let end = await outcome(of: link, within: 3)
        XCTAssertEqual(end, .ended(last: .cancelled), "close() must end a link that is still waiting to connect")
        XCTAssertEqual(link.state, .cancelled)
    }

    func testRefusedConnectionFailsAfterTheWaitingTimeout() async {
        let clock = ContinuousClock(), started = clock.now
        let link = Link.connect(to: refused, code: "1234", sharerName: "Sharer", hello: hello(.view), connectTimeout: 60, waitingTimeout: 0.5)
        let end = await outcome(of: link, within: 5)
        guard case .ended(last: .failed(let message)?) = end else { return XCTFail("expected .failed, got \(end)") }
        XCTAssertTrue(message.hasPrefix("Could not reach the other Mac"), message)
        XCTAssertGreaterThanOrEqual(clock.now - started, .milliseconds(450))
        if case .failed = link.state {} else { XCTFail("state is \(link.state)") }
    }

    func testPeerThatNeverAnswersFailsAtTheConnectDeadline() async throws {
        // Plain TCP that accepts and never speaks TLS: the handshake stalls without ever reporting .waiting.
        let silent = try SilentListener()
        let port = try await silent.start()
        let link = Link.connect(to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!), code: "1234",
                                sharerName: "Sharer", hello: hello(.view), connectTimeout: 1, waitingTimeout: 60)
        let end = await outcome(of: link, within: 5)
        guard case .ended(last: .failed(let message)?) = end else { return XCTFail("expected .failed, got \(end)") }
        XCTAssertTrue(message.hasPrefix("No answer from the other Mac"), message)
        silent.stop()
    }

    /// A pair of ready links on loopback, the sharer's end and the viewer's, with the hello each sends on `.ready` gone
    /// out, so a test starts from an empty backlog. Nil, with the test failed, when the pair never gets there: a
    /// regression that keeps links from `.ready` must fail the tests that need a pair, not skip them.
    private func readyPair(_ advertiser: Advertiser, port: UInt16) async -> (sharer: Link, viewer: Link)? {
        let viewer = Link.connect(to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!), code: "1234", sharerName: "Sharer", hello: hello(.view))
        var incoming = advertiser.incoming.makeAsyncIterator()
        guard let sharer = await incoming.next() else { XCTFail("no incoming link"); viewer.close(); return nil }
        for link in [sharer, viewer] { for await s in link.states where s == .ready { break } }
        guard sharer.state == .ready, viewer.state == .ready else {
            XCTFail("the pair never became ready: sharer \(sharer.state), viewer \(viewer.state)")
            sharer.close(); viewer.close()
            return nil
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while sharer.backlogBytes + viewer.backlogBytes > 0 {
            guard ContinuousClock.now < deadline else {
                XCTFail("the hellos were not sent within 2 s")
                sharer.close(); viewer.close()
                return nil
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return (sharer, viewer)
    }

    /// Network.framework expects `cancel()` after `.failed`; until then the connection holds on to what it uses, here
    /// until the link is freed. A wrong code fails the sharer's incoming link with the TLS error as `.failed`.
    func testAFailedConnectionIsCancelled() async throws {
        let advertiser = try Advertiser(name: "Sharer", code: "1234", hello: hello(.share))
        let port = try await advertiser.start()
        let viewer = Link.connect(to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!), code: "0000", sharerName: "Sharer", hello: hello(.view))
        var incoming = advertiser.incoming.makeAsyncIterator()
        guard let sharer = await incoming.next() else { return XCTFail("no incoming link") }
        let end = await outcome(of: sharer, within: 5)
        guard case .ended(last: .failed?) = end else { return XCTFail("expected .failed, got \(end)") }
        let deadline = ContinuousClock.now + .seconds(1)
        while sharer.connectionStateForTesting != .cancelled, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(sharer.connectionStateForTesting, .cancelled)
        if case .failed = sharer.state {} else { XCTFail("state is \(sharer.state)") }
        viewer.close(); advertiser.stop()
    }

    /// A link that has ended, or that this side is closing, drops what it is given: nothing waits in its backlog,
    /// nothing goes to a dead connection, and nothing logs a 'send:' error per message. That covers the viewer's ink
    /// and cursor while it reconnects after a drop, and the frames still leaving the encoder when the sharer says bye.
    func testALinkThatEndedTakesNoMessageAndLogsNoSendError() async throws {
        let advertiser = try Advertiser(name: "Sharer", code: "1234", hello: hello(.share))
        let port = try await advertiser.start()
        let stroke = Message.stroke(StrokeMessage(strokeId: 1, phase: .begin, color: .gold, baseWidth: 4,
                                                  points: [StrokePoint(x: 0.5, y: 0.5, pressure: 1, tMs: 0)]))

        // The sharer goes without bye; the viewer's link fails, and its ink keeps coming.
        guard let dropped = await readyPair(advertiser, port: port) else { return advertiser.stop() }
        dropped.sharer.abort()
        let viewerEnd = await outcome(of: dropped.viewer, within: 5)
        guard case .ended(last: .failed?) = viewerEnd else { return XCTFail("expected .failed, got \(viewerEnd)") }
        let afterDrop = LogMark()
        for _ in 0..<20 { dropped.viewer.send(stroke) }
        XCTAssertEqual(dropped.viewer.backlogBytes, 0, "a failed link took messages")
        try await Task.sleep(for: .milliseconds(200))
        let afterDropErrors = try afterDrop.entries("link").map(\.composedMessage).filter { $0.hasPrefix("send:") }
        XCTAssertEqual(afterDropErrors, [], "sends on a failed link logged errors")

        // The sharer says bye and sends right after it.
        guard let closed = await readyPair(advertiser, port: port) else { return advertiser.stop() }
        let atClose = LogMark()
        closed.sharer.close()
        for _ in 0..<20 { closed.sharer.send(stroke) }
        XCTAssertEqual(closed.sharer.backlogBytes, 0, "a closing link took messages")
        _ = await outcome(of: closed.sharer, within: 3)
        _ = await outcome(of: closed.viewer, within: 3)
        try await Task.sleep(for: .milliseconds(200))
        let atCloseErrors = try atClose.entries("link").map(\.composedMessage).filter { $0.hasPrefix("send:") }
        XCTAssertEqual(atCloseErrors, [], "sends after a bye logged errors")
        advertiser.stop()
    }

    func testPongSampleKeepsHonestSamplesAndDropsForgedOnes() {
        let sent: UInt64 = 999_990_000_000, now = 1_000.0   // sent at 999.99 s, answered at 1000 s
        let honest = Link.pongSample(sentTNs: sent, originalTNs: sent, replyTNs: 5_000_000_000_000, now: now)
        XCTAssertEqual(honest?.rttMs ?? -1, 10, accuracy: 1e-6)
        XCTAssertEqual(Double(honest?.offsetNs ?? 0), 5_000_000_000_000 - 999_995_000_000, accuracy: 1_000)
        XCTAssertNotNil(Link.pongSample(sentTNs: sent, originalTNs: sent, replyTNs: UInt64(Int64.max), now: now))

        // Each of these used to trap (Int64 of a UInt64 above Int64.max, Int64 of a Double past 2^63) or give nonsense.
        XCTAssertNil(Link.pongSample(sentTNs: sent, originalTNs: sent, replyTNs: UInt64.max, now: now))
        XCTAssertNil(Link.pongSample(sentTNs: sent, originalTNs: sent, replyTNs: UInt64(Int64.max) + 1, now: now))
        XCTAssertNil(Link.pongSample(sentTNs: sent, originalTNs: UInt64.max, replyTNs: 0, now: now))
        XCTAssertNil(Link.pongSample(sentTNs: sent, originalTNs: sent - 1, replyTNs: 0, now: now))
        XCTAssertNil(Link.pongSample(sentTNs: UInt64.max, originalTNs: UInt64.max, replyTNs: 0, now: now), "echoed time after now")
        XCTAssertNil(Link.pongSample(sentTNs: UInt64.max, originalTNs: UInt64.max, replyTNs: 0, now: 1e11), "midpoint past Int64.max")
    }

    func testReadsAndClosesFromManyThreadsWhileThePingsRun() async throws {
        let advertiser = try Advertiser(name: "Sharer", code: "1234", hello: hello(.share))
        let port = try await advertiser.start()
        let viewer = Link.connect(to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!), code: "1234", sharerName: "Sharer", hello: hello(.view))
        var incoming = advertiser.incoming.makeAsyncIterator()
        guard let sharer = await incoming.next() else { return XCTFail("no incoming link") }
        for link in [viewer, sharer] { for await s in link.states where s == .ready { break } }
        let readUntil = CACurrentMediaTime() + 1.2
        DispatchQueue.concurrentPerform(iterations: 8) { i in
            var seen = 0
            while CACurrentMediaTime() < readUntil {
                for link in [viewer, sharer] {
                    if case .failed = link.state { seen += 1 }
                    if link.peerHello != nil { seen += 1 }
                    if link.lastRTTMs != nil { seen += 1 }
                    if link.clockOffsetNs != nil { seen += 1 }
                    seen += link.backlogBytes
                }
            }
            if i == 0 { XCTAssertGreaterThan(seen, 0) }
        }
        XCTAssertNotNil(viewer.lastRTTMs)
        DispatchQueue.concurrentPerform(iterations: 8) { i in (i.isMultiple(of: 2) ? viewer : sharer).close() }
        let end = await outcome(of: viewer, within: 3)
        XCTAssertEqual(end, .ended(last: .cancelled))
        advertiser.stop()
    }

    // MARK: Advertiser

    func testListenerFailureAfterStartIsReportedAndEndsIncoming() async throws {
        let advertiser = try Advertiser(name: "Sharer", code: "1234", hello: hello(.share))
        let port = try await advertiser.start()
        advertiser.listenerStateChanged(.failed(.posix(.EADDRINUSE)))
        // The Bonjour registration (`.advertised`) may land anywhere in between; it says nothing about the listener.
        let states = await collect(advertiser.states, within: 3)?.filter { if case .advertised = $0 { return false }; return true }
        XCTAssertEqual(states?.first, .ready(port: port))
        guard case .failed(let message)? = states?.last else { return XCTFail("expected a final .failed, got \(String(describing: states))") }
        XCTAssertTrue(message.contains("Address already in use"), message)
        var incoming = advertiser.incoming.makeAsyncIterator()
        let next = await incoming.next()
        XCTAssertNil(next, "incoming must end once the listener is dead")
    }

    func testStopEndsStatesAndIncoming() async throws {
        let advertiser = try Advertiser(name: "Sharer", code: "1234", hello: hello(.share))
        let port = try await advertiser.start()
        advertiser.stop()
        let states = await collect(advertiser.states, within: 3)?.filter { if case .advertised = $0 { return false }; return true }
        XCTAssertEqual(states, [.ready(port: port), .stopped])
        var incoming = advertiser.incoming.makeAsyncIterator()
        let next = await incoming.next()
        XCTAssertNil(next)
    }

    // MARK: Browser

    func testBrowserSaysWhenLocalNetworkIsDeniedAndWhenDiscoveryFails() async {
        let browser = Browser()
        browser.browserStateChanged(.waiting(.dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied))))
        browser.browserStateChanged(.failed(.dns(DNSServiceErrorType(kDNSServiceErr_ServiceNotRunning))))
        let states = await collect(browser.states, within: 3)
        XCTAssertEqual(states?.count, 2)
        guard case .waiting(let denied)? = states?.first else { return XCTFail("expected .waiting first, got \(String(describing: states))") }
        XCTAssertTrue(denied.contains("Local Network"), denied)
        guard case .failed? = states?.last else { return XCTFail("expected .failed last, got \(String(describing: states))") }
        let lists = await collect(browser.peers, within: 3)
        XCTAssertEqual(lists, [[]], "a dead browser shows no peers and ends the list")
    }

    func testBrowserReportsReadyThenStopped() async {
        let browser = Browser()
        browser.start()
        let ready = await withTaskGroup(of: Bool.self) { group in
            group.addTask { for await s in browser.states { if s == .ready { return true } }; return false }
            group.addTask { try? await Task.sleep(for: .seconds(3)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        XCTAssertTrue(ready)
        browser.stop()
    }
}
