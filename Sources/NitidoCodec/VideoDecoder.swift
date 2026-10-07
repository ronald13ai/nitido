import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo
import NitidoCore
import os

private let log = Logger(subsystem: "ai.ronar.nitido", category: "codec")

public struct DecodedFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let captureHostTimeNs: UInt64
    public let seq: UInt32
}

/// Hardware decoder built from a `VideoConfig`. Rebuild it whenever a new config arrives.
/// Thread-safe: every member may be used from any thread, including `invalidate()` while another
/// thread is inside `decode(_:)`.
public final class VideoDecoder: @unchecked Sendable {
    public var onFrame: (@Sendable (DecodedFrame) -> Void)? {
        get { lock.withLock { frameHandler } }
        set { lock.withLock { frameHandler = newValue } }
    }
    /// Failures `init` and `decode(_:)` do not throw: a tuning property VideoToolbox rejected in
    /// `init` (RealTime; the decoder still works without it). Each one is also logged. Failures
    /// raised before this is set are delivered as soon as it is set.
    public var onError: (@Sendable (CodecError) -> Void)? {
        get { failures.onError }
        set { failures.onError = newValue }
    }

    private let lock = NSLock()
    private let failures = FailureChannel()
    // Guarded by `lock`. VideoToolbox is never called while it is held.
    private var session: VTDecompressionSession?
    private var frameHandler: (@Sendable (DecodedFrame) -> Void)?
    private let format: CMVideoFormatDescription

    public init(config: VideoConfig) throws {
        let sets = config.parameterSets
        let pointers = sets.map { set -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: max(set.count, 1))
            set.copyBytes(to: p, count: set.count); return p
        }
        defer { pointers.forEach { $0.deallocate() } }
        let immutable = pointers.map { UnsafePointer<UInt8>($0) }
        let sizes = sets.map(\.count)
        var fd: CMVideoFormatDescription?
        let status: OSStatus = immutable.withUnsafeBufferPointer { ptrs in
            sizes.withUnsafeBufferPointer { szs in
                config.codec == .hevc
                    ? CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: sets.count, parameterSetPointers: ptrs.baseAddress!, parameterSetSizes: szs.baseAddress!, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &fd)
                    : CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: sets.count, parameterSetPointers: ptrs.baseAddress!, parameterSetSizes: szs.baseAddress!, nalUnitHeaderLength: 4, formatDescriptionOut: &fd)
            }
        }
        guard status == noErr, let fd else { throw CodecError.formatDescription(status) }
        format = fd
        let attrs = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                     kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary
        var s: VTDecompressionSession?
        let st = VTDecompressionSessionCreate(allocator: nil, formatDescription: fd, decoderSpecification: nil,
                                              imageBufferAttributes: attrs, outputCallback: nil, decompressionSessionOut: &s)
        guard st == noErr, let s else { throw CodecError.sessionCreate(st) }
        session = s
        let realTime = VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        if realTime != noErr {
            failures.report(.property(kVTDecompressionPropertyKey_RealTime as String, realTime), "decoder property RealTime rejected")
        }
    }

    /// Synchronous: `onFrame` fires before this returns. Throws on malformed data.
    public func decode(_ frame: VideoFrame) throws {
        guard let session = lock.withLock({ self.session }) else { return }
        let data = frame.data
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil,
                                                        customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &block)
        guard status == noErr, let block else { throw CodecError.decode(status) }
        status = data.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
        }
        guard status == noErr else { throw CodecError.decode(status) }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMTime(value: CMTimeValue(frame.captureHostTimeNs / 1000), timescale: 1_000_000),
                                        decodeTimeStamp: .invalid)
        var size = data.count
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                           sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                           sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw CodecError.decode(status) }
        let seq = frame.seq, t = frame.captureHostTimeNs
        let callbackStatus = StatusBox()
        status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { [weak self] st, _, image, _, _ in
            callbackStatus.value = st
            guard st == noErr, let image, let self else { return }
            self.onFrame?(DecodedFrame(pixelBuffer: image, captureHostTimeNs: t, seq: seq))
        }
        let failure = status != noErr ? status : callbackStatus.value
        guard failure == noErr else {
            // A decode that raced `invalidate()` is teardown, not bad data: it ends like a decode
            // after `invalidate()`, without an error.
            if lock.withLock({ self.session == nil }) {
                log.debug("frame \(seq) ended by invalidate: \(failure)")
                return
            }
            throw CodecError.decode(failure)
        }
    }

    /// Releases the session. Safe to call while another thread is decoding; later calls to
    /// `decode` return without decoding.
    public func invalidate() {
        let taken: VTDecompressionSession? = lock.withLock { defer { session = nil }; return session }
        guard let taken else { return }
        VTDecompressionSessionInvalidate(taken)
    }

    deinit { invalidate() }
}

/// Carries the status out of VideoToolbox's `@Sendable` output handler.
private final class StatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var inner: OSStatus = noErr
    var value: OSStatus {
        get { lock.lock(); defer { lock.unlock() }; return inner }
        set { lock.lock(); inner = newValue; lock.unlock() }
    }
}
