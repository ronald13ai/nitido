import XCTest
import Network
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
