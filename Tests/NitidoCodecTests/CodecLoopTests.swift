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
    /// otherwise. HEVC unless `codec` says H.264.
    private func encodeFrames(_ count: Int, keyframesAt: Set<Int> = [], codec: Codec = .hevc) throws -> [EncodedFrame] {
        let encoder = try VideoEncoder(width: 640, height: 360, preferred: codec, bitsPerSecond: 4_000_000)
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

    /// One-pixel columns, black and white, at `width` × `height`: the finest detail a picture of text has.
    private func columns(width: Int, height: Int) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]]
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb), kCVReturnSuccess)
        let buffer = pb!
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width { let v: UInt8 = x % 2 == 0 ? 0 : 255; let p = base + y * stride + x * 4; p[0] = v; p[1] = v; p[2] = v; p[3] = 0xff }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    /// The first frame `codec` encodes from `source` at `bitsPerSecond`, decoded.
    private func roundTrip(_ source: CVPixelBuffer, codec: Codec, bitsPerSecond: Int = 60_000_000) throws -> DecodedFrame {
        let encoder = try VideoEncoder(width: CVPixelBufferGetWidth(source), height: CVPixelBufferGetHeight(source),
                                       preferred: codec, bitsPerSecond: bitsPerSecond)
        defer { encoder.invalidate() }
        let encoded = expectation(description: "encoded")
        let box = Box<[EncodedFrame]>([])
        encoder.onFrame = { f in box.append(f); encoded.fulfill() }
        XCTAssertTrue(encoder.encode(source, captureHostTimeNs: 0))
        wait(for: [encoded], timeout: 5)
        let frame = try XCTUnwrap(box.value.first)
        let decoder = try VideoDecoder(config: try XCTUnwrap(frame.videoConfig))
        defer { decoder.invalidate() }
        let decoded = Box<[DecodedFrame]>([])
        decoder.onFrame = { decoded.append($0) }
        try decoder.decode(frame.videoFrame)
        return try XCTUnwrap(decoded.value.first)
    }

    /// An odd size (a window of odd point size on a 1x display) is the normal case. HEVC and H.264 in 4:2:0 code no odd
    /// size, and VideoToolbox scaled 1347 × 879 to 1346 × 878, which blurred the one-pixel columns in the middle of the
    /// picture to grey. The encoder codes the even size above it from a copy with the edge repeated: the picture comes
    /// back at the source's size, and every pair of neighbouring columns keeps its contrast, across the whole width.
    func testAnOddSizeComesBackAtItsSizeWithEveryColumnSharp() throws {
        for codec in [Codec.hevc, .h264] {
            for (width, height) in [(1347, 879), (201, 101), (31, 17)] {
                let decoded = try roundTrip(columns(width: width, height: height), codec: codec)
                XCTAssertEqual(decoded.width, width, "\(codec) \(width)×\(height)")
                XCTAssertEqual(decoded.height, height)
                XCTAssertEqual(CVPixelBufferGetWidth(decoded.pixelBuffer), (width + 1) & ~1, "coded at the even size above")
                XCTAssertEqual(CVPixelBufferGetHeight(decoded.pixelBuffer), (height + 1) & ~1)
                guard width == 1347 else { continue }
                // The decoder's luma, one row in the middle and the last row of the picture.
                let buffer = decoded.pixelBuffer
                CVPixelBufferLockBaseAddress(buffer, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
                let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
                let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
                for y in [height / 2, height - 1] {
                    let row = luma + y * stride
                    let contrasts = (0..<(width - 1)).map { abs(Int(row[$0]) - Int(row[$0 + 1])) }
                    let weakest = contrasts.enumerated().min { $0.element < $1.element }!
                    XCTAssertGreaterThan(weakest.element, 100, "\(codec): columns \(weakest.offset) and \(weakest.offset + 1) of row \(y) blend")
                    let middle = contrasts[(width / 2 - 8)..<(width / 2 + 8)].min()!
                    XCTAssertGreaterThan(middle, 100, "\(codec): the middle of the picture keeps its columns")
                }
            }
        }
    }

    /// The hardware H.264 encoder takes up to 4096 × 2304. Over it, the failure says the picture is too large rather
    /// than a status a Retry at the same size would meet again.
    func testH264OverItsLimitSaysThePictureIsTooLarge() throws {
        XCTAssertNoThrow(try VideoEncoder(width: 4096, height: 2304, preferred: .h264, bitsPerSecond: 20_000_000).invalidate())
        XCTAssertThrowsError(try VideoEncoder(width: 4097, height: 2305, preferred: .h264, bitsPerSecond: 20_000_000)) { error in
            XCTAssertEqual(error as? CodecError, .tooLarge(width: 4097, height: 2305))
        }
        XCTAssertNoThrow(try VideoEncoder(width: 5120, height: 2880, preferred: .hevc, bitsPerSecond: 20_000_000).invalidate(),
                         "HEVC takes it")
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
    /// With HEVC, and with the encoder forced to H.264, the codec a Mac without a hardware HEVC encoder uses.
    func testDecodedPicturesCarryTheCapturesColourTags() throws {
        for codec in [Codec.hevc, .h264] {
            let frames = try encodeFrames(2, codec: codec)
            let config = try XCTUnwrap(frames.first?.videoConfig)
            XCTAssertEqual(config.codec, codec)
            let decoder = try VideoDecoder(config: config)
            defer { decoder.invalidate() }
            let out = Box<[DecodedFrame]>([])
            decoder.onFrame = { out.append($0) }
            for f in frames { try decoder.decode(f.videoFrame) }
            XCTAssertEqual(out.value.count, 2, "\(codec)")
            for picture in out.value.map(\.pixelBuffer) {
                XCTAssertEqual(CVPixelBufferGetPixelFormatType(picture), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, "\(codec)")
                func tag(_ key: CFString) -> String? { CVBufferCopyAttachment(picture, key, nil) as? String }
                XCTAssertEqual(tag(kCVImageBufferColorPrimariesKey), kCVImageBufferColorPrimaries_ITU_R_709_2 as String, "\(codec)")
                XCTAssertEqual(tag(kCVImageBufferTransferFunctionKey), kCVImageBufferTransferFunction_sRGB as String, "\(codec)")
                XCTAssertEqual(tag(kCVImageBufferYCbCrMatrixKey), kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String, "\(codec)")
            }
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
        for start in stride(from: 0, to: frames.count, by: VideoDecoder.maxWaiting) {
            let group = frames[start..<min(start + VideoDecoder.maxWaiting, frames.count)]
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

    /// A decoder on `clock` that has shown `key`, with nothing left waiting.
    private func decoderThatShowed(_ key: EncodedFrame, clock: ManualClock) throws -> VideoDecoder {
        let decoder = try VideoDecoder(config: try XCTUnwrap(key.videoConfig), clock: { clock.now })
        let shown = Box<[UInt32]>([])
        decoder.onFrame = { shown.append($0.seq) }
        XCTAssertEqual(decoder.submit(key.videoFrame), .queued)
        decoder.drainForTesting()   // `decode` hands each picture to `onFrame` before it returns
        XCTAssertEqual(shown.value, [key.seq])
        return decoder
    }

    /// Spec 4: the decoder judges itself behind by how long a frame has waited, not by how many wait. Four deltas handed
    /// over within 5 ms while the decoder's queue is held (a main thread that was busy, a network that delivered them
    /// at once) are all queued and all decoded, in order: none is skipped and no keyframe is asked for.
    func testFramesHandedOverInABurstAreAllDecoded() throws {
        let frames = try encodeFrames(5)
        let clock = ManualClock()
        let decoder = try decoderThatShowed(frames[0], clock: clock)
        defer { decoder.invalidate() }
        let seqs = Box<[UInt32]>([]), superseded = Box<[UInt32]>([])
        decoder.onFrame = { seqs.append($0.seq) }
        decoder.onSuperseded = { superseded.append($0) }
        decoder.suspendForTesting()
        var results: [VideoDecoder.SubmitResult] = []
        for (i, frame) in frames[1...4].enumerated() {
            clock.set(Double([0, 2, 4, 5][i]) / 1000)
            results.append(decoder.submit(frame.videoFrame))
        }
        decoder.resumeForTesting()
        decoder.drainForTesting()
        XCTAssertEqual(results, Array(repeating: .queued, count: 4), "a burst within 5 ms is not falling behind")
        XCTAssertEqual(seqs.value, [1, 2, 3, 4], "every frame of the burst decoded, in order")
        XCTAssertEqual(superseded.value, [])
    }

    /// Spec 4 and 8: the decoder drops work rather than queue it. A frame that has waited more than 50 ms on the
    /// decoder's clock (three frame intervals at 60 fps; the queue held here, as a stall would) means the decoder fell
    /// behind: at exactly 50 ms the next delta still waits, at 60 ms the one after it starts a skip to the next keyframe
    /// and says what was waiting, the delta after that is skipped quietly (it refers to the one skipped), and the
    /// keyframe ends the skip and starts the count again, so the delta after it decodes. The two that waited are dropped
    /// undecoded when the queue moves (`onSuperseded`), since nothing from the keyframe on refers to them: the keyframe
    /// that recovers the picture does not decode behind frames it replaces.
    func testAFrameThatWaitedPastFiftyMillisecondsMakesTheNextDeltaSkipToTheKeyframe() throws {
        let frames = try encodeFrames(7, keyframesAt: [5])
        XCTAssertTrue(frames[0].isKey); XCTAssertTrue(frames[5].isKey)
        XCTAssertTrue(frames[1...4].allSatisfy { !$0.isKey }); XCTAssertFalse(frames[6].isKey)
        let clock = ManualClock()
        let decoder = try decoderThatShowed(frames[0], clock: clock)
        defer { decoder.invalidate() }
        let seqs = Box<[UInt32]>([]), superseded = Box<[UInt32]>([])
        decoder.onFrame = { seqs.append($0.seq) }
        decoder.onSuperseded = { superseded.append($0) }
        decoder.suspendForTesting()
        let first = decoder.submit(frames[1].videoFrame)
        clock.set(0.050)
        let atFifty = decoder.submit(frames[2].videoFrame)
        clock.set(0.060)
        let rest = frames[3...6].map { decoder.submit($0.videoFrame) }
        decoder.resumeForTesting()
        decoder.drainForTesting()
        XCTAssertEqual(first, .queued)
        XCTAssertEqual(atFifty, .queued, "50 ms is not more than 50 ms")
        XCTAssertEqual(rest[0], .fellBehind(.init(frames: 2, oldestWait: 0.060)), "the oldest waited 60 ms")
        XCTAssertEqual(rest[1], .skipped, "the delta after a skipped one is skipped too")
        XCTAssertEqual(rest[2], .queued, "a keyframe ends the skip")
        XCTAssertEqual(rest[3], .queued, "the delta after the keyframe decodes")
        XCTAssertEqual(superseded.value, [1, 2], "the keyframe superseded the deltas still waiting")
        XCTAssertEqual(seqs.value, [5, 6])
    }

    /// However quickly they come, no more than eight frames wait: on a clock that never moves, eight deltas handed over
    /// at once are queued and decoded, and the ninth starts a skip to the next keyframe.
    func testNoMoreThanEightFramesWait() throws {
        let frames = try encodeFrames(11)
        let clock = ManualClock()
        let decoder = try decoderThatShowed(frames[0], clock: clock)
        defer { decoder.invalidate() }
        let seqs = Box<[UInt32]>([])
        decoder.onFrame = { seqs.append($0.seq) }
        decoder.suspendForTesting()
        let results = frames[1...10].map { decoder.submit($0.videoFrame) }
        decoder.resumeForTesting()
        decoder.drainForTesting()
        XCTAssertEqual(VideoDecoder.maxWaiting, 8)
        XCTAssertEqual(Array(results[0..<8]), Array(repeating: .queued, count: 8))
        XCTAssertEqual(results[8], .fellBehind(.init(frames: 8, oldestWait: 0)), "the ninth: eight wait already")
        XCTAssertEqual(results[9], .skipped)
        XCTAssertEqual(seqs.value, Array(1...8))
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

/// A clock a test sets by hand, for `VideoDecoder(config:clock:)`, in seconds from 0.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: Double = 0
    var now: Double { lock.withLock { seconds } }
    func set(_ value: Double) { lock.withLock { seconds = value } }
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
