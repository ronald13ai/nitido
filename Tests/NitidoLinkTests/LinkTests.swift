import XCTest
import Network
import QuartzCore
import NitidoTestSupport
@testable import NitidoLink
@testable import NitidoCore

final class LinkTests: XCTestCase {
    private func hello(_ role: Role) -> Hello { Hello(protocolVersion: protocolVersion, role: role, name: role == .share ? "Sharer" : "Viewer", pixelWidth: 1920, pixelHeight: 1080, scale: 2) }

    private func waitReady(_ link: Link) async throws {
        for await s in link.states {
            if s == .ready { return }
            if case .failed(let m) = s { throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: m]) }
            if s == .cancelled { throw NSError(domain: "test", code: 2) }
        }
    }

    func testFramesStrokesAndPingsFlowBothWays() async throws {
        let advertiser = try Advertiser(name: "Sharer", code: "1234", hello: hello(.share))
        let port = try await advertiser.start()
        let viewer = Link.connect(to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!), code: "1234", sharerName: "Sharer", hello: hello(.view))
        var iterator = advertiser.incoming.makeAsyncIterator()
        guard let sharer = await iterator.next() else { return XCTFail("no incoming link") }
        try await waitReady(sharer); try await waitReady(viewer)

        let collector = Task { () -> [Message] in
            var got: [Message] = []
            for await m in viewer.messages {
                got.append(m)
                if case .stroke = m { break }
            }
            return got
        }
        sharer.send(.videoConfig(VideoConfig(codec: .hevc, width: 1920, height: 1080, parameterSets: [Data([1, 2, 3])])))
        for i in 0..<100 { sharer.send(.videoFrame(VideoFrame(seq: UInt32(i), captureHostTimeNs: UInt64(i), isKey: i == 0, data: Data(repeating: UInt8(i), count: 20_000)))) }
        sharer.send(.stroke(StrokeMessage(strokeId: 2, phase: .begin, color: .gold, baseWidth: 4, points: [StrokePoint(x: 0.5, y: 0.5, pressure: 1, tMs: 0)])))
        let got = await collector.value
        XCTAssertEqual(got.count, 103, "hello + config + 100 frames + stroke")
        guard case .hello(let h) = got[0] else { return XCTFail("first message must be hello") }
        XCTAssertEqual(h.name, "Sharer"); XCTAssertEqual(viewer.peerHello?.role, .share); XCTAssertEqual(sharer.peerHello?.role, .view)
        guard case .videoFrame(let last) = got[101] else { return XCTFail() }
        XCTAssertEqual(last.seq, 99); XCTAssertEqual(last.data.count, 20_000)

        try await Task.sleep(for: .milliseconds(1_300))
        XCTAssertNotNil(viewer.lastRTTMs); XCTAssertNotNil(sharer.lastRTTMs); XCTAssertNotNil(viewer.clockOffsetNs)
        XCTAssertLessThan(viewer.lastRTTMs ?? 1000, 50)
        XCTAssertEqual(viewer.backlogBytes, 0)

        viewer.send(.undo(strokeId: 2))
        var sharerIterator = sharer.messages.makeAsyncIterator()
        var seen: Message?
        while let m = await sharerIterator.next() { if case .undo = m { seen = m; break } }
        XCTAssertEqual(seen, .undo(strokeId: 2))
        viewer.close(); sharer.close(); advertiser.stop()
    }

    func testWrongCodeFailsTheHandshake() async throws {
        let advertiser = try Advertiser(name: "Sharer", code: "1234", hello: hello(.share))
        let port = try await advertiser.start()
        let viewer = Link.connect(to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!), code: "0000", sharerName: "Sharer", hello: hello(.view))
        var failed = false
        for await s in viewer.states {
            if case .failed = s { failed = true; break }
            if s == .cancelled { break }
        }
        XCTAssertTrue(failed)
        advertiser.stop()
    }

    /// A pair of ready links on loopback: the sharer's end and the viewer's.
    private func readyPair(_ advertiser: Advertiser, port: UInt16) async throws -> (sharer: Link, viewer: Link) {
        let viewer = Link.connect(to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!), code: "1234", sharerName: "Sharer", hello: hello(.view))
        var iterator = advertiser.incoming.makeAsyncIterator()
        guard let sharer = await iterator.next() else { throw NSError(domain: "test", code: 3, userInfo: [NSLocalizedDescriptionKey: "no incoming link"]) }
        try await waitReady(sharer); try await waitReady(viewer)
        return (sharer, viewer)
    }

    /// The final state a link's `states` ends on.
    private func finalState(_ link: Link) async -> Link.State? {
        var last: Link.State?
        for await s in link.states { last = s }
        return last
    }

    /// The sharer's dropping rule leaves the keyframe on its way out of the backlog, the oldest one still being sent,
    /// and counts every other message: the keyframes queued behind it and the frames behind those (spec section 8,
    /// `backlogBytesExcludingKeyframes`). Keyframes stacked up (a viewer asking for one after another) are a backlog
    /// like any other: eight megabytes of them read as all but one keyframe, not as nothing. Both figures go back to
    /// zero once the sends complete.
    func testOnlyTheKeyframeOnItsWayIsLeftOutOfTheBacklog() async throws {
        let advertiser = try Advertiser(name: "Sharer", code: "1234", hello: hello(.share))
        let port = try await advertiser.start()
        let (sharer, viewer) = try await readyPair(advertiser, port: port)
        func drained() async -> Bool {
            let deadline = ContinuousClock.now + .seconds(5)
            while sharer.backlogBytes > 0 || sharer.backlogBytesExcludingKeyframes != 0 {
                guard ContinuousClock.now < deadline else { return false }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return true
        }
        let helloOut = await drained()
        XCTAssertTrue(helloOut, "the hello was not sent within 5 s")

        // Eight megabytes of keyframes: they take longer to send than this thread takes to read the figures.
        func keyframe(_ seq: UInt32) -> Message {
            .videoFrame(VideoFrame(seq: seq, captureHostTimeNs: 0, isKey: true, data: Data(count: 400_000)))
        }
        let size = Wire.encode(keyframe(0)).count
        for i in 0..<20 { sharer.send(keyframe(UInt32(i))) }
        let (total, excluding) = sharer.backlogFiguresForTesting
        XCTAssertGreaterThanOrEqual(total, 2 * size, "the keyframes wait to be sent")
        XCTAssertEqual(excluding, total - size, "only the keyframe on its way is left out; the ones behind it count")
        let delta = Message.videoFrame(VideoFrame(seq: 20, captureHostTimeNs: 0, isKey: false, data: Data(count: 1_000)))
        sharer.send(delta)
        let (withDelta, excludingWithDelta) = sharer.backlogFiguresForTesting
        XCTAssertEqual(excludingWithDelta, withDelta - size, "the delta behind them counts too")

        let allOut = await drained()
        XCTAssertTrue(allOut, "the frames were not sent within 5 s")
        XCTAssertEqual(sharer.backlogBytes, 0)
        XCTAssertEqual(sharer.backlogBytesExcludingKeyframes, 0)

        // The test seam follows the same rule: the first keyframe held is the one on its way.
        sharer.addBacklogForTesting(150_000, keyframe: true)
        sharer.addBacklogForTesting(150_000, keyframe: true)
        sharer.addBacklogForTesting(40_000)
        XCTAssertEqual(sharer.backlogBytes, 340_000)
        XCTAssertEqual(sharer.backlogBytesExcludingKeyframes, 190_000, "the second keyframe and the 40 kB count")
        sharer.addBacklogForTesting(-150_000, keyframe: true)
        XCTAssertEqual(sharer.backlogBytesExcludingKeyframes, 40_000, "the second keyframe is the one on its way now")
        sharer.addBacklogForTesting(-150_000, keyframe: true)
        XCTAssertEqual(sharer.backlogBytesExcludingKeyframes, 40_000)
        sharer.addBacklogForTesting(-40_000)
        XCTAssertEqual(sharer.backlogBytes, 0)
        viewer.close(); sharer.close(); advertiser.stop()
    }

    /// A `bye` carries its reason (`ByeReason`) to the other side, which ends as `.cancelled`, not as a failure.
    func testAByeCarriesItsReason() async throws {
        let advertiser = try Advertiser(name: "Sharer", code: "1234", hello: hello(.share))
        let port = try await advertiser.start()
        let (sharer, viewer) = try await readyPair(advertiser, port: port)
        XCTAssertNil(viewer.byeReason)
        sharer.close(reason: ByeReason.sharingStopped)
        let ended = await finalState(viewer)
        XCTAssertEqual(ended, .cancelled)
        XCTAssertEqual(viewer.byeReason, ByeReason.sharingStopped)
        advertiser.stop()
    }

    /// `closeAndWait` returns once the `bye` is out, well before the one-second fallback: the other side ends on the
    /// bye (`.cancelled`, reason `ended`), not on a dropped connection. A link that never became ready returns at once.
    func testCloseAndWaitReturnsOnceTheByeIsOut() async throws {
        let advertiser = try Advertiser(name: "Sharer", code: "1234", hello: hello(.share))
        let port = try await advertiser.start()
        let (sharer, viewer) = try await readyPair(advertiser, port: port)
        let started = CACurrentMediaTime()
        await viewer.closeAndWait()
        XCTAssertLessThan(CACurrentMediaTime() - started, 0.9, "the bye's send completed; the fallback did not have to")
        let ended = await finalState(sharer)
        XCTAssertEqual(ended, .cancelled)
        XCTAssertEqual(sharer.byeReason, ByeReason.ended)

        let unready = Link.connect(to: .hostPort(host: "127.0.0.1", port: 1), code: "1234", sharerName: "Sharer", hello: hello(.view))
        let again = CACurrentMediaTime()
        await unready.closeAndWait()
        XCTAssertLessThan(CACurrentMediaTime() - again, 0.5, "nothing to say bye on: cancelled at once")
        advertiser.stop()
    }

    /// A `bye` often comes with the end of the stream in the same delivery, or just before the receive the closed
    /// connection cancels. Either way the link ends on the bye (`.cancelled`) and logs no error claiming the other side
    /// left without one, or that the receive failed (a clean stop or Back left those false errors behind). The sharer
    /// that closed logs none either.
    func testAByeLogsNoFalseErrorOnEitherSide() async throws {
        let mark = LogMark()
        let advertiser = try Advertiser(name: "Sharer", code: "1234", hello: hello(.share))
        let port = try await advertiser.start()
        for _ in 0..<5 {
            let (sharer, viewer) = try await readyPair(advertiser, port: port)
            sharer.close()
            let viewerEnded = await finalState(viewer), sharerEnded = await finalState(sharer)
            XCTAssertEqual(viewerEnded, .cancelled)
            XCTAssertEqual(sharerEnded, .cancelled)
        }
        advertiser.stop()
        try await Task.sleep(for: .milliseconds(200))
        let falseErrors = try mark.entries("link")
            .map(\.composedMessage)
            .filter { $0.contains("closed the connection without bye") || $0.contains("receive failed") }
        XCTAssertEqual(falseErrors, [], "a link that ended on a bye logged a failure")
    }

    func testClosingOneSideEndsTheOther() async throws {
        let advertiser = try Advertiser(name: "Sharer", code: "1234", hello: hello(.share))
        let port = try await advertiser.start()
        let viewer = Link.connect(to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!), code: "1234", sharerName: "Sharer", hello: hello(.view))
        var iterator = advertiser.incoming.makeAsyncIterator()
        guard let sharer = await iterator.next() else { return XCTFail() }
        try await waitReady(sharer); try await waitReady(viewer)
        sharer.close()
        var ended = false
        for await s in viewer.states { if s == .cancelled { ended = true; break }; if case .failed = s { ended = true; break } }
        XCTAssertTrue(ended)
        advertiser.stop()
    }
}
