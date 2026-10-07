import XCTest
@testable import NitidoCore

final class WireTests: XCTestCase {
    private let samples: [Message] = [
        .hello(Hello(protocolVersion: 1, role: .share, name: "Ronald's Mac", pixelWidth: 3024, pixelHeight: 1964, scale: 2)),
        .videoConfig(VideoConfig(codec: .hevc, width: 3024, height: 1964, parameterSets: [Data([0x40, 0x01]), Data([0x42, 0x01, 0x01]), Data([0x44])])),
        .videoFrame(VideoFrame(seq: 7, captureHostTimeNs: 123_456_789_012, isKey: true, data: Data(repeating: 0xab, count: 1000))),
        .stroke(StrokeMessage(strokeId: 3, phase: .append, color: RGB(r: 201, g: 168, b: 106), baseWidth: 3.5,
                              points: [StrokePoint(x: 0.1, y: 0.2, pressure: 1, tMs: 10), StrokePoint(x: 0.3, y: 0.4, pressure: 0.5, tMs: 26)])),
        .cursor(Cursor(x: 0.5, y: 0.75, visible: true)),
        .ping(id: 9, tNs: 42),
        .pong(id: 9, originalTNs: 42, replyTNs: 43),
        .keyframeRequest,
        .undo(strokeId: 3),
        .clear,
        .bye(reason: 1),
    ]

    func testBigEndianWriterAndReader() throws {
        var w = ByteWriter()
        w.u16(0x1234); w.u32(0x89abcdef); w.u64(0x0102030405060708); w.f32(1.5); w.string8("hé")
        XCTAssertEqual(Array(w.data.prefix(6)), [0x12, 0x34, 0x89, 0xab, 0xcd, 0xef])
        var r = ByteReader(w.data)
        XCTAssertEqual(try r.u16(), 0x1234)
        XCTAssertEqual(try r.u32(), 0x89abcdef)
        XCTAssertEqual(try r.u64(), 0x0102030405060708)
        XCTAssertEqual(try r.f32(), 1.5)
        XCTAssertEqual(try r.string8(), "hé")
        XCTAssertTrue(r.isAtEnd)
        XCTAssertThrowsError(try r.u8())
    }

    func testEveryMessageRoundTrips() throws {
        for m in samples {
            var d = Wire.Decoder()
            let out = try d.feed(Wire.encode(m))
            XCTAssertEqual(out, [m], "round trip failed for \(m)")
        }
    }

    func testHeaderIsLengthThenType() {
        let data = Wire.encode(.ping(id: 1, tNs: 2))
        XCTAssertEqual(Array(data.prefix(5)), [0, 0, 0, 12, 6])  // payload 4 + 8 bytes, type 6
        XCTAssertEqual(data.count, 17)
    }

    func testDecoderSurvivesByteByByteFeeding() throws {
        let all = samples.map(Wire.encode).reduce(Data(), +)
        var d = Wire.Decoder()
        var out: [Message] = []
        for b in all { out += try d.feed(Data([b])) }
        XCTAssertEqual(out, samples)
    }

    func testDecoderHandlesManyMessagesInOneChunk() throws {
        let all = samples.map(Wire.encode).reduce(Data(), +)
        var d = Wire.Decoder()
        XCTAssertEqual(try d.feed(all), samples)
        XCTAssertEqual(try d.feed(Data()), [])
    }

    func testUnknownTypeIsSkipped() throws {
        var w = ByteWriter(); w.u32(3); w.u8(200); w.bytes(Data([1, 2, 3]))
        var d = Wire.Decoder()
        let out = try d.feed(w.data + Wire.encode(.clear))
        XCTAssertEqual(out, [.clear])
    }

    func testOversizedLengthThrows() {
        var w = ByteWriter(); w.u32(UInt32(Wire.maxPayload + 1)); w.u8(3)
        var d = Wire.Decoder()
        XCTAssertThrowsError(try d.feed(w.data)) { XCTAssertEqual($0 as? WireError, .oversized(Wire.maxPayload + 1)) }
    }

    func testTruncatedKnownPayloadThrows() {
        var w = ByteWriter(); w.u32(2); w.u8(6); w.bytes(Data([0, 0]))  // ping needs 12 bytes, declares 2
        var d = Wire.Decoder()
        XCTAssertThrowsError(try d.feed(w.data)) { XCTAssertEqual($0 as? WireError, .truncated) }
    }

    func testStringLongerThan255BytesIsCut() throws {
        let long = String(repeating: "a", count: 300)
        var d = Wire.Decoder()
        let out = try d.feed(Wire.encode(.hello(Hello(protocolVersion: 1, role: .view, name: long, pixelWidth: 1, pixelHeight: 1, scale: 1))))
        guard case .hello(let h) = out[0] else { return XCTFail() }
        XCTAssertEqual(h.name.count, 255)
    }

    func testNonASCIIStringLongerThan255BytesIsCutAtScalarBoundary() throws {
        // 200 x "\u{00E9}" is 400 UTF-8 bytes; a raw 255-byte cut would split a character.
        let long = String(repeating: "\u{00E9}", count: 200)
        var d = Wire.Decoder()
        let out = try d.feed(Wire.encode(.hello(Hello(protocolVersion: 1, role: .view, name: long, pixelWidth: 1, pixelHeight: 1, scale: 1))))
        guard case .hello(let h) = out[0] else { return XCTFail() }
        XCTAssertLessThanOrEqual(h.name.utf8.count, 255)
        XCTAssertEqual(h.name.utf8.count, 254)
        XCTAssertEqual(h.name, String(repeating: "\u{00E9}", count: 127))
    }

    func testFourByteScalarsAreNotSplit() throws {
        // 70 x U+1F600 is 280 UTF-8 bytes; 63 scalars (252 bytes) fit.
        let long = String(repeating: "\u{1F600}", count: 70)
        var w = ByteWriter(); w.string8(long)
        var r = ByteReader(w.data)
        let back = try r.string8()
        XCTAssertTrue(r.isAtEnd)
        XCTAssertEqual(back.utf8.count, 252)
        XCTAssertEqual(back, String(repeating: "\u{1F600}", count: 63))
    }
}
