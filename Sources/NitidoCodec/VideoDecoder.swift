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
    /// The picture's size, from the stream's `VideoConfig`. The buffer can be a column wider or a row taller: the
    /// encoder codes an odd size at the even one above it (`VideoEncoder.codedWidth`), and the picture is the buffer's
    /// top left `width` × `height`.
    public let width: Int
    public let height: Int
}

/// Hardware decoder built from a `VideoConfig`. Rebuild it whenever a new config arrives.
///
/// `submit(_:)` is the way in for a stream: it decodes on the decoder's own serial queue, in the order the frames came
/// (inter-coded frames refer to the ones before them, so none can be skipped on its own), and it drops work rather than
/// queue it (spec 4). It judges itself behind by how long the oldest frame still waiting has waited on its clock, not by
/// how many wait: frames handed over in a burst a few milliseconds apart (a main thread that was busy, a network that
/// delivered several at once) are all decoded. Once the oldest has waited more than `maxWait`, or `maxWaiting` frames
/// wait, it skips to the next keyframe and the caller asks for one; a keyframe drops the frames still waiting before it
/// (`onSuperseded`). The renderer then shows the newest decoded frame. `decode(_:)` decodes one frame on the calling
/// thread.
///
/// Thread-safe: every member may be used from any thread, including `invalidate()` while another
/// thread is inside `decode(_:)`.
public final class VideoDecoder: @unchecked Sendable {
    /// What `submit(_:)` did with a frame.
    public enum SubmitResult: Sendable, Equatable {
        /// The frame waits for, or is in, the decoder's queue.
        case queued
        /// The decoder had fallen behind (`backlog` says how far): the frame is not decoded, and it begins a skip to the
        /// next keyframe, which the caller asks for.
        case fellBehind(Backlog)
        /// A skip is under way and no keyframe has ended it yet: the frame is not decoded.
        case skipped
    }

    /// The frames waiting when a skip began: how many (the one in the decoder included) and how long the oldest of them
    /// had waited, in seconds on the decoder's clock.
    public struct Backlog: Sendable, Equatable {
        public let frames: Int
        public let oldestWait: Double
        public init(frames: Int, oldestWait: Double) { self.frames = frames; self.oldestWait = oldestWait }
    }

    /// A delta is skipped once the oldest frame still waiting has waited longer than this, in seconds: three frame
    /// intervals at 60 fps. A frame waits from its submit until its decode ends.
    public static let maxWait: Double = 0.050
    /// And whatever their age, no more than this many frames wait: the next delta is skipped.
    public static let maxWaiting = 8

    /// The decoder's clock, in seconds: the system's uptime.
    public static func uptime() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

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
    /// A frame `submit(_:)` queued that a keyframe submitted after it superseded before its turn came, with its
    /// sequence number. Nothing from that keyframe on refers to it, so it is dropped undecoded rather than decoded
    /// ahead of the keyframe. Called on the decoder's queue, in submit order; not after `invalidate()`.
    public var onSuperseded: (@Sendable (_ seq: UInt32) -> Void)? {
        get { lock.withLock { supersededHandler } }
        set { lock.withLock { supersededHandler = newValue } }
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
    private var supersededHandler: (@Sendable (UInt32) -> Void)?
    /// When each frame submitted since the newest keyframe that has not been decoded yet was submitted, oldest first, on
    /// `clock`.
    private var waitingSince: [Double] = []
    /// A frame was skipped, so every delta up to the next keyframe is too: it refers to the skipped one.
    private var skipping = false
    /// Bumped by every keyframe submitted. Nothing after a keyframe refers to the frames before it: those still waiting
    /// are dropped undecoded (`onSuperseded`), and none counts in `waitingSince` any more.
    private var keyEpoch: UInt64 = 0
    private let clock: @Sendable () -> Double
    private let format: CMVideoFormatDescription
    /// The picture's size, which every `DecodedFrame` carries (`config.width` × `config.height`).
    private let pictureWidth: Int, pictureHeight: Int
    private let queue = DispatchQueue(label: "ai.ronar.nitido.decoder", qos: .userInteractive)

    /// `clock` says how long a frame has waited (`submit`), in seconds; a test can give its own.
    public init(config: VideoConfig, clock: @escaping @Sendable () -> Double = VideoDecoder.uptime) throws(CodecError) {
        self.clock = clock
        pictureWidth = Int(config.width); pictureHeight = Int(config.height)
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
        // The decoder's own 4:2:0, video range, with no conversion on the way out. Core Image turns it into RGB on the
        // GPU as it draws, with the matrix and transfer function the stream's colour tags put on every picture
        // (`VideoEncoder`). Measured on an M5 at 2692 × 1756: 1.2 ms to decode a picture this way against 4 ms as BGRA,
        // 7 MB a picture against 19 MB, and no slower to draw.
        let attrs = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
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
    /// `onFrame` (a failure to `onDecodeFailure`). A keyframe is always queued, ends a skip, and supersedes the frames
    /// still waiting before it: each goes to `onSuperseded` instead of the decoder. A delta is skipped once the oldest
    /// frame still waiting has waited more than `maxWait`, or `maxWaiting` frames wait (`.fellBehind`), and so is every
    /// delta after it until the next keyframe (`.skipped`): they refer to the one skipped. Never blocks the caller.
    @discardableResult
    public func submit(_ frame: VideoFrame) -> SubmitResult {
        let admitted: (epoch: UInt64?, result: SubmitResult) = lock.withLock {
            let now = clock()
            if frame.isKey {
                skipping = false; keyEpoch &+= 1; waitingSince.removeAll()
            } else if skipping {
                return (nil, .skipped)
            } else if let oldest = waitingSince.first, now - oldest > Self.maxWait || waitingSince.count >= Self.maxWaiting {
                skipping = true
                return (nil, .fellBehind(Backlog(frames: waitingSince.count, oldestWait: now - oldest)))
            }
            waitingSince.append(now)
            return (keyEpoch, .queued)
        }
        guard let epoch = admitted.epoch else { return admitted.result }
        queue.async { [self] in
            // A keyframe submitted since this frame starts what is shown next, and nothing from it on refers to this
            // one: decoding it would only hold the keyframe up.
            if lock.withLock({ session != nil && keyEpoch != epoch }) {
                onSuperseded?(frame.seq)
                return
            }
            defer { lock.withLock { if keyEpoch == epoch, !waitingSince.isEmpty { waitingSince.removeFirst() } } }
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
        let seq = frame.seq, t = frame.captureHostTimeNs, width = pictureWidth, height = pictureHeight
        let callbackStatus = StatusBox()
        status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { [weak self] st, _, image, _, _ in
            callbackStatus.value = st
            guard st == noErr, let image, let self else { return }
            self.onFrame?(DecodedFrame(pixelBuffer: image, captureHostTimeNs: t, seq: seq, width: width, height: height))
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
