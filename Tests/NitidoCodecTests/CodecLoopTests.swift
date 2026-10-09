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

    /// `count` frames from the hardware encoder, in order: a keyframe first and at every index in `keyframesAt`, deltas
    /// otherwise.
    private func encodeFrames(_ count: Int, keyframesAt: Set<Int> = []) throws -> [EncodedFrame] {
        let encoder = try VideoEncoder(width: 640, height: 360, preferred: .hevc, bitsPerSecond: 4_000_000)
        defer { encoder.invalidate() }
        let encoded = expectation(description: "\(count) encoded"); encoded.expectedFulfillmentCount = count
        let box = Box<[EncodedFrame]>([])
        encoder.onFrame = { f in box.append(f); encoded.fulfill() }
        for i in 0..<count {
            if keyframesAt.contains(i) { encoder.requestKeyframe() }
            XCTAssertTrue(encoder.encode(makeFrame(index: i), captureHostTimeNs: UInt64(i) * 16_666_667)); usleep(5_000)
        }
        wait(for: [encoded], timeout: 5)
        return box.value.sorted { $0.seq < $1.seq }
    }

    func testEncodeThenDecodeThirtyFrames() throws {
        let frames = try encodeFrames(30)
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
        decoder.invalidate()
    }

    /// The stream says what the capture is (BT.709 primaries, the sRGB transfer function, the BT.709 matrix), and every
    /// decoded picture carries it, in the decoder's own 4:2:0, so Core Image draws the captured colours back in sRGB.
    func testDecodedPicturesCarryTheCapturesColourTags() throws {
        let frames = try encodeFrames(2)
        let decoder = try VideoDecoder(config: try XCTUnwrap(frames.first?.videoConfig))
        defer { decoder.invalidate() }
        let out = Box<[DecodedFrame]>([])
        decoder.onFrame = { out.append($0) }
        for f in frames { try decoder.decode(f.videoFrame) }
        XCTAssertEqual(out.value.count, 2)
        for picture in out.value.map(\.pixelBuffer) {
            XCTAssertEqual(CVPixelBufferGetPixelFormatType(picture), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            func tag(_ key: CFString) -> String? { CVBufferCopyAttachment(picture, key, nil) as? String }
            XCTAssertEqual(tag(kCVImageBufferColorPrimariesKey), kCVImageBufferColorPrimaries_ITU_R_709_2 as String)
            XCTAssertEqual(tag(kCVImageBufferTransferFunctionKey), kCVImageBufferTransferFunction_sRGB as String)
            XCTAssertEqual(tag(kCVImageBufferYCbCrMatrixKey), kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
        }
    }

    /// `submit` decodes on the decoder's own queue, never on the calling thread (the main actor, in the app), and in the
    /// order the frames came, which inter-coded frames need. Frames go in as many at a time as may wait, so none is
    /// skipped.
    func testSubmitDecodesInOrderOffTheCallingThread() throws {
        XCTAssertTrue(Thread.isMainThread)
        let frames = try encodeFrames(30)
        let decoder = try VideoDecoder(config: try XCTUnwrap(frames.first?.videoConfig))
        let seqs = Box<[UInt32]>([]), onMain = Box<[Bool]>([]), failures = Box<[UInt32]>([])
        decoder.onDecodeFailure = { seq, _ in failures.append(seq) }
        for start in stride(from: 0, to: frames.count, by: VideoDecoder.maxPending) {
            let group = frames[start..<min(start + VideoDecoder.maxPending, frames.count)]
            let decoded = expectation(description: "frames from \(start)"); decoded.expectedFulfillmentCount = group.count
            decoder.onFrame = { d in seqs.append(d.seq); onMain.append(Thread.isMainThread); decoded.fulfill() }
            for f in group { XCTAssertEqual(decoder.submit(f.videoFrame), .queued, "frame \(f.seq)") }
            wait(for: [decoded], timeout: 5)
            decoder.drainForTesting()   // the last frame no longer counts as waiting, so the next group fits
        }
        XCTAssertEqual(seqs.value, Array(0..<30), "decoded in the order submitted")
        XCTAssertFalse(onMain.value.contains(true), "decoded on the calling thread")
        XCTAssertEqual(failures.value, [])
        decoder.invalidate()
    }

    /// A frame `submit` cannot decode is reported with its sequence number, not thrown at the caller.
    func testSubmitReportsAFrameItCannotDecodeWithItsSeq() throws {
        let frames = try encodeFrames(1)
        let decoder = try VideoDecoder(config: try XCTUnwrap(frames.first?.videoConfig))
        let failed = expectation(description: "onDecodeFailure")
        let reported = Box<[(seq: UInt32, error: CodecError)]>([])
        decoder.onDecodeFailure = { seq, error in reported.append((seq, error)); failed.fulfill() }
        let garbage = VideoFrame(seq: 1, captureHostTimeNs: 1, isKey: false, data: Data([0, 0, 0, 3, 1, 2, 3]))
        XCTAssertEqual(decoder.submit(garbage), .queued)
        wait(for: [failed], timeout: 5)
        XCTAssertEqual(reported.value.map(\.seq), [1])
        guard case .decode? = reported.value.first?.error else { return XCTFail("expected .decode, got \(reported.value)") }
        decoder.invalidate()
    }

    /// Spec 4 and 8: the decoder drops work rather than queue it. With three frames waiting (the queue held here, as a
    /// stall would), the next delta is skipped and asks for a keyframe once, the deltas after it are skipped quietly
    /// (they refer to the one skipped), and the keyframe ends the skip and starts the count again, so the delta after
    /// it decodes. The three that waited are dropped undecoded when the queue moves (`onSuperseded`), since nothing
    /// from the keyframe on refers to them: no more than three frames ever wait to be decoded, and the keyframe that
    /// recovers the picture does not decode behind frames it replaces.
    func testSubmitSkipsToTheNextKeyframeWhenThreeFramesWait() throws {
        let frames = try encodeFrames(8, keyframesAt: [6])
        XCTAssertTrue(frames[0].isKey); XCTAssertTrue(frames[6].isKey)
        XCTAssertTrue(frames[1...5].allSatisfy { !$0.isKey }); XCTAssertFalse(frames[7].isKey)
        let decoder = try VideoDecoder(config: try XCTUnwrap(frames[0].videoConfig))
        let first = expectation(description: "the keyframe")
        decoder.onFrame = { _ in first.fulfill() }
        XCTAssertEqual(decoder.submit(frames[0].videoFrame), .queued)
        wait(for: [first], timeout: 5)
        decoder.drainForTesting()

        let seqs = Box<[UInt32]>([]), superseded = Box<[UInt32]>([])
        decoder.onFrame = { d in seqs.append(d.seq) }
        decoder.onSuperseded = { seq in superseded.append(seq) }
        decoder.suspendForTesting()
        for i in 1...3 { XCTAssertEqual(decoder.submit(frames[i].videoFrame), .queued, "delta \(i)") }
        XCTAssertEqual(decoder.submit(frames[4].videoFrame), .skipped(askForKeyframe: true))
        XCTAssertEqual(decoder.submit(frames[5].videoFrame), .skipped(askForKeyframe: false))
        XCTAssertEqual(decoder.submit(frames[6].videoFrame), .queued, "a keyframe ends the skip")
        XCTAssertEqual(decoder.submit(frames[7].videoFrame), .queued, "the delta after the keyframe decodes")
        decoder.resumeForTesting()
        decoder.drainForTesting()   // `decode` hands each picture to `onFrame` before it returns
        XCTAssertEqual(superseded.value, [1, 2, 3], "the keyframe superseded the deltas still waiting")
        XCTAssertEqual(seqs.value, [6, 7])
        decoder.invalidate()
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
