import XCTest
import CoreVideo
import VideoToolbox
@testable import NitidoCodec
@testable import NitidoCore

/// Teardown races and failure reporting for the encoder and decoder.
final class CodecSafetyTests: XCTestCase {
    private func solidFrame(width: Int = 320, height: Int = 180, format: OSType = kCVPixelFormatType_32BGRA) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:]]
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, format, attrs as CFDictionary, &pb), kCVReturnSuccess)
        return pb!
    }

    // MARK: Teardown races

    /// The sharer encodes on the capture queue while the main actor swaps handlers and stops the share.
    func testInvalidateRacingEncodeAndHandlerSwap() throws {
        for round in 0..<10 {
            let encoder = try VideoEncoder(width: 320, height: 180, preferred: .hevc, bitsPerSecond: 2_000_000)
            let errors = Box<[CodecError]>([])
            encoder.onError = { errors.append($0) }
            let frame = Box(solidFrame())
            let group = DispatchGroup()
            DispatchQueue.global().async(group: group) {
                for i in 0..<30 { _ = encoder.encode(frame.value, captureHostTimeNs: UInt64(i)); usleep(300) }
            }
            DispatchQueue.global().async(group: group) {
                for _ in 0..<30 { encoder.onFrame = { _ in }; usleep(200) }
            }
            DispatchQueue.global().async(group: group) { usleep(UInt32(1_000 + round * 500)); encoder.invalidate() }
            XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
            XCTAssertFalse(encoder.encode(frame.value, captureHostTimeNs: 99), "an invalidated encoder accepts nothing")
            encoder.setBitrate(-1)   // would be rejected on a live session; after invalidate it is a no-op
            XCTAssertEqual(errors.value, [], "stopping a share is not an encoder failure")
        }
    }

    /// The viewer decodes on its link queue while the main actor swaps handlers and drops the decoder.
    func testInvalidateRacingDecodeAndHandlerSwap() throws {
        let key = try encodeOneKeyframe()
        for round in 0..<10 {
            let decoder = try VideoDecoder(config: key.videoConfig!)
            let thrown = Box<[String]>([])
            let group = DispatchGroup()
            DispatchQueue.global().async(group: group) {
                for _ in 0..<30 {
                    do { try decoder.decode(key.videoFrame) } catch { thrown.append("\(error)") }
                    usleep(200)
                }
            }
            DispatchQueue.global().async(group: group) {
                for _ in 0..<30 { decoder.onFrame = { _ in }; usleep(150) }
            }
            DispatchQueue.global().async(group: group) { usleep(UInt32(1_000 + round * 400)); decoder.invalidate() }
            XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
            XCTAssertEqual(thrown.value, [], "dropping the decoder is not a decode failure")
            XCTAssertNoThrow(try decoder.decode(key.videoFrame), "decoding after invalidate is a no-op")
        }
    }

    // MARK: Failure reporting

    /// VideoToolbox accepts the frame (encode returns true), then fails it on its own queue.
    /// Before the fix this was only logged, so the share froze with no error.
    func testAsynchronousEncodeFailureReachesOnError() throws {
        let encoder = try VideoEncoder(width: 320, height: 180, preferred: .hevc, bitsPerSecond: 2_000_000)
        let failed = expectation(description: "onError")
        let errors = Box<[CodecError]>([])
        encoder.onError = { errors.append($0); failed.fulfill() }
        let frames = Box<[EncodedFrame]>([])
        encoder.onFrame = { frames.append($0) }
        // A depth buffer has no conversion path into the HEVC encoder: refused asynchronously.
        XCTAssertTrue(encoder.encode(solidFrame(format: kCVPixelFormatType_DepthFloat32), captureHostTimeNs: 0))
        wait(for: [failed], timeout: 5)
        guard case .encode(let status)? = errors.value.first else { return XCTFail("expected .encode, got \(errors.value)") }
        XCTAssertNotEqual(status, noErr)
        XCTAssertTrue(frames.value.isEmpty)

        // The encoder keeps running after a failed frame.
        let next = expectation(description: "next frame")
        encoder.onFrame = { _ in next.fulfill() }
        XCTAssertTrue(encoder.encode(solidFrame(), captureHostTimeNs: 1))
        wait(for: [next], timeout: 5)
        encoder.invalidate()
    }

    /// A keyframe request stands until a frame carrying it is emitted (spec 14: a keyframe request produces a keyframe
    /// within one frame). The frame that took it here is accepted, then failed by VideoToolbox, so the frame after it
    /// is forced instead; otherwise the request would be used up and the next keyframe would come 120 frames later.
    func testAForcedKeyframeThatFailsIsForcedAgain() throws {
        let encoder = try VideoEncoder(width: 320, height: 180, preferred: .hevc, bitsPerSecond: 2_000_000)
        let first = expectation(description: "first frame")
        encoder.onFrame = { _ in first.fulfill() }
        XCTAssertTrue(encoder.encode(solidFrame(), captureHostTimeNs: 0))
        wait(for: [first], timeout: 5)

        encoder.requestKeyframe()
        let failed = expectation(description: "onError")
        failed.assertForOverFulfill = false
        encoder.onError = { _ in failed.fulfill() }
        // A depth buffer has no conversion path into the HEVC encoder: accepted, then failed asynchronously.
        XCTAssertTrue(encoder.encode(solidFrame(format: kCVPixelFormatType_DepthFloat32), captureHostTimeNs: 1))
        wait(for: [failed], timeout: 5)
        XCTAssertTrue(encoder.isKeyframeRequested, "the failed frame leaves the request standing")

        let next = expectation(description: "next frame")
        let after = Box<[EncodedFrame]>([])
        encoder.onFrame = { after.append($0); next.fulfill() }
        XCTAssertTrue(encoder.encode(solidFrame(), captureHostTimeNs: 2))
        wait(for: [next], timeout: 5)
        let frame = try XCTUnwrap(after.value.first)
        XCTAssertTrue(frame.isKey, "the frame after the failed one carries the keyframe request")
        XCTAssertFalse(frame.parameterSets.isEmpty, "a keyframe carries its parameter sets")
        XCTAssertFalse(encoder.isKeyframeRequested, "the emitted keyframe used the request up")
        encoder.invalidate()
    }

    /// A bitrate VideoToolbox rejects at runtime reaches `onError` on the calling thread.
    func testRejectedBitrateReachesOnError() throws {
        let encoder = try VideoEncoder(width: 320, height: 180, preferred: .hevc, bitsPerSecond: 2_000_000)
        let errors = Box<[CodecError]>([])
        encoder.onError = { errors.append($0) }
        encoder.setBitrate(2_500_000)
        XCTAssertEqual(errors.value, [])
        encoder.setBitrate(-1)
        guard case .property(let key, let status)? = errors.value.first else { return XCTFail("expected .property, got \(errors.value)") }
        XCTAssertEqual(key, kVTCompressionPropertyKey_AverageBitRate as String)
        XCTAssertNotEqual(status, noErr)
        encoder.invalidate()
    }

    /// A tuning property rejected inside `init` (before any handler exists) is held, then
    /// delivered as soon as `onError` is set, and the encoder still works.
    func testPropertyRejectedDuringInitIsDeliveredWhenOnErrorIsSet() throws {
        let encoder = try VideoEncoder(width: 320, height: 180, preferred: .hevc, bitsPerSecond: -1)
        let errors = Box<[CodecError]>([])
        encoder.onError = { errors.append($0) }
        guard case .property(let key, _)? = errors.value.first else { return XCTFail("expected .property, got \(errors.value)") }
        XCTAssertEqual(key, kVTCompressionPropertyKey_AverageBitRate as String)
        let got = expectation(description: "frame")
        encoder.onFrame = { _ in got.fulfill() }
        XCTAssertTrue(encoder.encode(solidFrame(), captureHostTimeNs: 0))
        wait(for: [got], timeout: 5)
        encoder.invalidate()
    }

    /// `nextSeq` moves only when the encoder takes a frame. The share model counts a frame `encode` turned away
    /// (two in flight, or invalidated) as dropped only when it did not move: a frame refused after it was taken
    /// reaches `onError` and is counted there.
    func testNextSeqMovesOnlyWhenTheEncoderTakesAFrame() throws {
        let encoder = try VideoEncoder(width: 320, height: 180, preferred: .hevc, bitsPerSecond: 2_000_000)
        let got = expectation(description: "frame")
        encoder.onFrame = { _ in got.fulfill() }
        XCTAssertEqual(encoder.nextSeq, 0)
        XCTAssertTrue(encoder.encode(solidFrame(), captureHostTimeNs: 0))
        XCTAssertEqual(encoder.nextSeq, 1)
        wait(for: [got], timeout: 5)
        encoder.invalidate()
        XCTAssertFalse(encoder.encode(solidFrame(), captureHostTimeNs: 1))
        XCTAssertEqual(encoder.nextSeq, 1, "a frame turned away takes no sequence number")
    }

    func testFailureChannelHoldsUntilAHandlerIsSet() {
        let channel = FailureChannel()
        for i in 0..<(FailureChannel.capacity + 4) { channel.report(.encode(OSStatus(-i)), "test \(i)") }
        let seen = Box<[CodecError]>([])
        channel.onError = { seen.append($0) }
        XCTAssertEqual(seen.value, (0..<FailureChannel.capacity).map { .encode(OSStatus(-$0)) }, "the first ones, in order")
        channel.report(.frameDropped, "direct")
        XCTAssertEqual(seen.value.last, .frameDropped)
        channel.onError = nil
        channel.report(.missingData, "held again")
        XCTAssertEqual(seen.value.count, FailureChannel.capacity + 1)
        channel.onError = { seen.append($0) }
        XCTAssertEqual(seen.value.last, .missingData)
    }

    private func encodeOneKeyframe() throws -> EncodedFrame {
        let encoder = try VideoEncoder(width: 320, height: 180, preferred: .hevc, bitsPerSecond: 2_000_000)
        let got = expectation(description: "keyframe")
        let box = Box<[EncodedFrame]>([])
        encoder.onFrame = { f in box.append(f); got.fulfill() }
        XCTAssertTrue(encoder.encode(solidFrame(), captureHostTimeNs: 0))
        wait(for: [got], timeout: 5)
        encoder.invalidate()
        return box.value[0]
    }
}
