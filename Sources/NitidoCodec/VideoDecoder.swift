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
///
/// `submit(_:)` is the way in for a stream: it decodes on the decoder's own serial queue, in the order the frames came
/// (inter-coded frames refer to the ones before them, so none can be skipped on its own), and it drops work rather than
/// queue it (spec 4): past `maxPending` frames waiting it skips to the next keyframe, and the caller asks for one. The
/// renderer then shows the newest decoded frame. `decode(_:)` decodes one frame on the calling thread.
///
/// Thread-safe: every member may be used from any thread, including `invalidate()` while another
/// thread is inside `decode(_:)`.
public final class VideoDecoder: @unchecked Sendable {
    /// What `submit(_:)` did with a frame.
    public enum SubmitResult: Sendable, Equatable {
        /// The frame waits for, or is in, the decoder's queue.
        case queued
        /// The frame is not decoded: `maxPending` frames were waiting, or a skip began and no keyframe has ended it
        /// yet. `askForKeyframe` is true for the frame that began the skip, false for the ones after it.
        case skipped(askForKeyframe: Bool)
    }

    /// At most this many frames since the newest keyframe wait for, or are in, the queue (`submit`).
    static let maxPending = 3

    /// Called on the decoder's queue, in decode order, by `submit(_:)` and `decode(_:)`.
    public var onFrame: (@Sendable (DecodedFrame) -> Void)? {
        get { lock.withLock { frameHandler } }
        set { lock.withLock { frameHandler = newValue } }
    }
    /// A frame `submit(_:)` could not decode (bad data), with its sequence number. Called on the decoder's queue, in
    /// decode order; each one is logged here. Frames cut short by `invalidate()` are not failures and are not reported.
    public var onDecodeFailure: (@Sendable (_ seq: UInt32, _ error: CodecError) -> Void)? {
        get { lock.withLock { decodeFailureHandler } }
        set { lock.withLock { decodeFailureHandler = newValue } }
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
    private var decodeFailureHandler: (@Sendable (UInt32, CodecError) -> Void)?
    /// Frames submitted since the newest keyframe that have not been decoded yet.
    private var pending = 0
    /// A frame was skipped, so every delta up to the next keyframe is too: it refers to the skipped one.
    private var skipping = false
    /// Bumped by every keyframe submitted. Nothing after a keyframe refers to the frames before it: they still decode,
    /// but no longer count in `pending`.
    private var keyEpoch: UInt64 = 0
    private let format: CMVideoFormatDescription
    private let queue = DispatchQueue(label: "ai.ronar.nitido.decoder", qos: .userInteractive)

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

    /// Decodes `frame` on the decoder's queue, after every frame submitted before it, and hands the picture to
    /// `onFrame` (a failure to `onDecodeFailure`). A keyframe is always queued, and ends a skip. A delta is skipped
    /// while `maxPending` frames since the newest keyframe are waiting, and so is every delta after it until the next
    /// keyframe; the first one skipped says to ask for that keyframe. Never blocks the caller.
    @discardableResult
    public func submit(_ frame: VideoFrame) -> SubmitResult {
        let admitted: (epoch: UInt64?, result: SubmitResult) = lock.withLock {
            if frame.isKey {
                skipping = false; keyEpoch &+= 1; pending = 0
            } else if skipping {
                return (nil, .skipped(askForKeyframe: false))
            } else if pending >= Self.maxPending {
                skipping = true
                return (nil, .skipped(askForKeyframe: true))
            }
            pending += 1
            return (keyEpoch, .queued)
        }
        guard let epoch = admitted.epoch else { return admitted.result }
        queue.async { [self] in
            defer { lock.withLock { if keyEpoch == epoch { pending -= 1 } } }
            do throws(CodecError) {
                try decode(frame)
            } catch {
                guard lock.withLock({ session != nil }) else {
                    log.debug("frame \(frame.seq) ended by invalidate: \(String(describing: error))")
                    return
                }
                log.error("could not decode frame \(frame.seq, privacy: .public): \(String(describing: error), privacy: .public)")
                onDecodeFailure?(frame.seq, error)
            }
        }
        return .queued
    }

    /// Decodes on the calling thread: `onFrame` fires before this returns. Throws on malformed data. A stream goes
    /// through `submit(_:)`, which runs this on the decoder's queue.
    public func decode(_ frame: VideoFrame) throws(CodecError) {
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
    /// `decode` return without decoding, and frames still waiting in the queue end without a word.
    public func invalidate() {
        let taken: VTDecompressionSession? = lock.withLock { defer { session = nil }; return session }
        guard let taken else { return }
        VTDecompressionSessionInvalidate(taken)
    }

    // MARK: Test seams

    /// Test only: holds the queue, as a stall would; frames submitted meanwhile wait.
    func suspendForTesting() { queue.suspend() }
    func resumeForTesting() { queue.resume() }
    /// Test only: returns once every frame submitted so far has been decoded and no longer counts as waiting.
    func drainForTesting() { queue.sync {} }

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
