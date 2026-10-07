import XCTest
import CoreVideo
@testable import NitidoCodec
@testable import NitidoCore

final class CodecLoopTests: XCTestCase {
    /// A BGRA buffer with a moving diagonal so every frame differs.
    private func makeFrame(index: Int, width: Int = 640, height: Int = 360) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]]
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb), kCVReturnSuccess)
        let buffer = pb!
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let p = base + y * stride + x * 4
                let on = (x + y + index * 7) % 64 < 32
                p[0] = on ? 0x6a : 0x0c; p[1] = on ? 0xa8 : 0x09; p[2] = on ? 0xc9 : 0x08; p[3] = 0xff
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    func testEncodeThenDecodeThirtyFrames() throws {
        let encoder = try VideoEncoder(width: 640, height: 360, preferred: .hevc, bitsPerSecond: 4_000_000)
        let encoded = expectation(description: "30 encoded"); encoded.expectedFulfillmentCount = 30
        let box = Box<[EncodedFrame]>([])
        encoder.onFrame = { f in box.append(f); encoded.fulfill() }
        for i in 0..<30 { XCTAssertTrue(encoder.encode(makeFrame(index: i), captureHostTimeNs: UInt64(i) * 16_666_667)); usleep(5_000) }
        wait(for: [encoded], timeout: 5)
        let frames = box.value.sorted { $0.seq < $1.seq }
        XCTAssertEqual(frames.count, 30)
        XCTAssertTrue(frames[0].isKey)
        XCTAssertFalse(frames[0].parameterSets.isEmpty)
        XCTAssertTrue(frames[1...].allSatisfy { !$0.isKey })
        XCTAssertEqual(frames[0].seq, 0); XCTAssertEqual(frames[29].captureHostTimeNs, 29 * 16_666_667)

        let decoder = try VideoDecoder(config: frames[0].videoConfig!)
        let decoded = expectation(description: "30 decoded"); decoded.expectedFulfillmentCount = 30
        let out = Box<[DecodedFrame]>([])
        decoder.onFrame = { d in out.append(d); decoded.fulfill() }
        for f in frames { try decoder.decode(f.videoFrame) }
        wait(for: [decoded], timeout: 5)
        XCTAssertEqual(out.value.count, 30)
        XCTAssertEqual(CVPixelBufferGetWidth(out.value[0].pixelBuffer), 640)
        XCTAssertEqual(CVPixelBufferGetHeight(out.value[0].pixelBuffer), 360)
        XCTAssertEqual(out.value.map(\.seq).sorted(), Array(0..<30))
        encoder.invalidate(); decoder.invalidate()
    }

    func testKeyframeRequestAndBitrateChange() throws {
        let encoder = try VideoEncoder(width: 320, height: 180, preferred: .hevc, bitsPerSecond: 2_000_000)
        let got = expectation(description: "frames"); got.expectedFulfillmentCount = 6
        let box = Box<[EncodedFrame]>([])
        encoder.onFrame = { f in box.append(f); got.fulfill() }
        for i in 0..<3 { _ = encoder.encode(makeFrame(index: i, width: 320, height: 180), captureHostTimeNs: UInt64(i)); usleep(5_000) }
        encoder.setBitrate(1_000_000)
        encoder.requestKeyframe()
        for i in 3..<6 { _ = encoder.encode(makeFrame(index: i, width: 320, height: 180), captureHostTimeNs: UInt64(i)); usleep(5_000) }
        wait(for: [got], timeout: 5)
        let frames = box.value.sorted { $0.seq < $1.seq }
        XCTAssertTrue(frames[3].isKey, "the frame after requestKeyframe must be a keyframe")
        XCTAssertFalse(frames[3].parameterSets.isEmpty)
        encoder.invalidate()
    }

    func testDecoderRejectsGarbageWithoutCrashing() throws {
        let encoder = try VideoEncoder(width: 320, height: 180, preferred: .hevc, bitsPerSecond: 2_000_000)
        let got = expectation(description: "one")
        let box = Box<[EncodedFrame]>([])
        encoder.onFrame = { f in box.append(f); got.fulfill() }
        _ = encoder.encode(makeFrame(index: 0, width: 320, height: 180), captureHostTimeNs: 0)
        wait(for: [got], timeout: 5)
        let decoder = try VideoDecoder(config: box.value[0].videoConfig!)
        XCTAssertThrowsError(try decoder.decode(VideoFrame(seq: 1, captureHostTimeNs: 1, isKey: false, data: Data([0, 0, 0, 3, 1, 2, 3]))))
        decoder.invalidate(); encoder.invalidate()
    }
}

/// Thread-safe collector for callbacks that arrive on VideoToolbox's queues.
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var inner: T
    init(_ v: T) { inner = v }
    var value: T { lock.lock(); defer { lock.unlock() }; return inner }
}
extension Box where T: RangeReplaceableCollection {
    func append(_ e: T.Element) { lock.lock(); inner.append(e); lock.unlock() }
}
