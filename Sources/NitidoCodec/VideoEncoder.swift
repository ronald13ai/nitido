import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo
import NitidoCore
import os

private let log = Logger(subsystem: "ai.ronar.nitido", category: "codec")

public enum CodecError: Error, Equatable {
    case sessionCreate(OSStatus)
    case encode(OSStatus)
    case decode(OSStatus)
    case formatDescription(OSStatus)
    /// VideoToolbox rejected a session property; the string is the property key, such as "DataRateLimits".
    case property(String, OSStatus)
    /// `VTCompressionSessionPrepareToEncodeFrames` failed.
    case prepare(OSStatus)
    /// VideoToolbox dropped a frame that `encode` had accepted: a realtime encoder under load lets frames go. A dropped
    /// frame, not a failure (`VideoEncoder.onError`).
    case frameDropped
    /// VideoToolbox emitted an encoded frame with no data.
    case missingData

    /// One sentence for the person using the app (spec 9: errors in plain language), with VideoToolbox's status at the
    /// end. Logs keep `String(describing:)`, which names the case.
    public var plainDescription: String {
        switch self {
        case .sessionCreate(let status): "The hardware video session could not start (error \(status))."
        case .encode(let status): "The hardware encoder could not encode a frame (error \(status))."
        case .decode(let status): "The video decoder could not read a frame (error \(status))."
        case .formatDescription(let status): "The video setup could not be read (error \(status))."
        case .property(let key, let status): "The video codec rejected the \(Self.settingName(key)) setting (error \(status))."
        case .prepare(let status): "The hardware encoder could not get ready (error \(status))."
        case .frameDropped: "The hardware encoder dropped a frame."
        case .missingData: "The hardware encoder produced an empty frame."
        }
    }

    /// VideoToolbox's status inside a sentence the app writes itself, " (error -12908)", for whoever reads the log
    /// alongside; empty for a failure that has none.
    public var statusNote: String {
        switch self {
        case .sessionCreate(let status), .encode(let status), .decode(let status), .formatDescription(let status),
             .property(_, let status), .prepare(let status):
            " (error \(status))"
        case .frameDropped, .missingData:
            ""
        }
    }

    /// What a VideoToolbox property key is called in a sentence: "average bitrate" for "AverageBitRate"; a key not
    /// listed is said as it is.
    public static func settingName(_ key: String) -> String { settingNames[key] ?? key }

    private static let settingNames: [String: String] = [
        kVTCompressionPropertyKey_AverageBitRate as String: "average bitrate",
        kVTCompressionPropertyKey_DataRateLimits as String: "data rate limit",
        kVTCompressionPropertyKey_RealTime as String: "real-time",   // the decoder's key is the same string
        kVTCompressionPropertyKey_ProfileLevel as String: "profile",
        kVTCompressionPropertyKey_MaxKeyFrameInterval as String: "keyframe interval",
        kVTCompressionPropertyKey_ExpectedFrameRate as String: "frame rate",
        kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String: "speed priority",
        kVTCompressionPropertyKey_AllowFrameReordering as String: "frame reordering",
        kVTCompressionPropertyKey_ColorPrimaries as String: "colour primaries",
        kVTCompressionPropertyKey_TransferFunction as String: "transfer function",
        kVTCompressionPropertyKey_YCbCrMatrix as String: "colour matrix",
    ]
}

public struct EncodedFrame: Sendable {
    public let seq: UInt32
    public let captureHostTimeNs: UInt64
    public let isKey: Bool
    /// NAL units with 4-byte big-endian length prefixes, exactly as VideoToolbox emits them.
    public let data: Data
    /// VPS/SPS/PPS (HEVC) or SPS/PPS (H.264); present on keyframes only.
    public let parameterSets: [Data]
    public let codec: Codec
    public let width: Int
    public let height: Int

    public var videoConfig: VideoConfig? {
        parameterSets.isEmpty ? nil : VideoConfig(codec: codec, width: UInt16(width), height: UInt16(height), parameterSets: parameterSets)
    }
    public var videoFrame: VideoFrame { VideoFrame(seq: seq, captureHostTimeNs: captureHostTimeNs, isKey: isKey, data: data) }
}

/// Realtime hardware encoder. Thread-safe: every member may be used from any thread, including
/// `invalidate()` while another thread is inside `encode(_:captureHostTimeNs:)`.
/// `onFrame` is called on a VideoToolbox queue; `onError` on a VideoToolbox queue, or on the
/// calling thread for a failure inside `encode` or `setBitrate`.
public final class VideoEncoder: @unchecked Sendable {
    public let codec: Codec
    public let width: Int
    public let height: Int
    public var onFrame: (@Sendable (EncodedFrame) -> Void)? {
        get { lock.withLock { frameHandler } }
        set { lock.withLock { frameHandler = newValue } }
    }
    /// Every encoder failure that does not throw: a frame `encode` accepted that VideoToolbox then
    /// failed or dropped, a frame VideoToolbox refused inside `encode`, and a tuning property
    /// VideoToolbox rejected (in `init` or `setBitrate`). Each one is also logged: a failure as an
    /// error, a dropped frame (`.frameDropped`, a realtime encoder under load) at info and at most once
    /// a second (`DropLog`). The encoder keeps running; the caller decides what the UI shows. Failures
    /// raised before this is set (a property rejected inside `init`) are delivered as soon as it is
    /// set. Frames cut short by `invalidate()` are not failures and are not reported.
    public var onError: (@Sendable (CodecError) -> Void)? {
        get { failures.onError }
        set { failures.onError = newValue }
    }

    private let lock = NSLock()
    private let failures = FailureChannel()
    // Guarded by `lock`. VideoToolbox is never called while it is held: the output handler can run
    // on the calling thread and takes the lock itself.
    private var session: VTCompressionSession?
    private var frameHandler: (@Sendable (EncodedFrame) -> Void)?
    private var seq: UInt32 = 0
    private var forceKey = true
    private var inFlight = 0
    private var drops = DropLog()

    public init(width: Int, height: Int, preferred: Codec = .hevc, bitsPerSecond: Int) throws(CodecError) {
        self.width = width; self.height = height
        let spec = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary
        func create(_ type: CMVideoCodecType) -> (OSStatus, VTCompressionSession?) {
            var s: VTCompressionSession?
            let st = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: type,
                                                encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &s)
            return (st, s)
        }
        var (status, created) = create(preferred == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264)
        var chosen = preferred
        if status != noErr, preferred == .hevc {
            log.warning("no hardware HEVC encoder (\(status)), falling back to H.264")
            (status, created) = create(kCMVideoCodecType_H264); chosen = .h264
        }
        guard status == noErr, let s = created else { throw CodecError.sessionCreate(status) }
        codec = chosen
        session = s
        do throws(CodecError) {
            try configure(s, codec: chosen, bitsPerSecond: bitsPerSecond)
        } catch {
            invalidate()
            throw error
        }
    }

    /// RealTime and no frame reordering are required: without them VideoToolbox may hold frames
    /// back (lookahead, B-frames), which stalls the two-in-flight cap and breaks in-order decoding,
    /// so a rejection throws, and so does a failed prepare. The rest are tuning: a rejection leaves
    /// VideoToolbox's default in place and goes to `onError`.
    ///
    /// The colour tags say what the capture is: sRGB (`CaptureSession`), so BT.709 primaries with
    /// the sRGB transfer function, and the BT.709 matrix the encoder turns its RGB into YCbCr with.
    /// They travel in the stream, the decoder attaches them to every picture, and Core Image draws
    /// the captured colours back into the sRGB layer. Untagged, the decoder took the sRGB values
    /// for BT.709's transfer function, and the viewer's colours were off by up to 12 code values.
    private func configure(_ s: VTCompressionSession, codec: Codec, bitsPerSecond: Int) throws(CodecError) {
        try require(s, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        try require(s, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        tune(s, kVTCompressionPropertyKey_ProfileLevel,
             codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel)
        tune(s, kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        tune(s, kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_sRGB)
        tune(s, kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        tune(s, kVTCompressionPropertyKey_MaxKeyFrameInterval, Self.keyframeInterval as CFNumber)
        tune(s, kVTCompressionPropertyKey_ExpectedFrameRate, Self.frameRate as CFNumber)
        tune(s, kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanFalse)
        setBitrate(bitsPerSecond)
        let status = VTCompressionSessionPrepareToEncodeFrames(s)
        guard status == noErr else {
            log.error("prepare to encode: \(status)")
            throw CodecError.prepare(status)
        }
    }

    private func require(_ s: VTCompressionSession, _ key: CFString, _ value: CFTypeRef?) throws(CodecError) {
        let status = VTSessionSetProperty(s, key: key, value: value)
        guard status == noErr else {
            log.error("required property \(key as String, privacy: .public) rejected: \(status)")
            throw CodecError.property(key as String, status)
        }
    }

    private func tune(_ s: VTCompressionSession, _ key: CFString, _ value: CFTypeRef?) {
        let status = VTSessionSetProperty(s, key: key, value: value)
        guard status != noErr else { return }
        guard !isInvalidated else {
            log.debug("property \(key as String, privacy: .public) not set, encoder invalidated: \(status)")
            return
        }
        failures.report(.property(key as String, status), "property \(key as String) rejected")
    }

    private var isInvalidated: Bool { lock.withLock { session == nil } }

    public func setBitrate(_ bitsPerSecond: Int) {
        guard let session = lock.withLock({ self.session }) else { return }
        tune(session, kVTCompressionPropertyKey_AverageBitRate, bitsPerSecond as CFNumber)
        let limit = Self.dataRateLimit(bitsPerSecond: bitsPerSecond)
        tune(session, kVTCompressionPropertyKey_DataRateLimits, [limit.bytes, limit.seconds] as CFArray)
    }

    /// A periodic keyframe every 120 frames, 2 s at the 60 fps the encoder expects.
    static let keyframeInterval = 120
    static let frameRate = 60

    /// The hard cap on bytes (`DataRateLimits`, spec 7): twice the average over one keyframe interval, 2 s, a window
    /// that always holds one periodic keyframe and the deltas that pay for it. At 1.5 times the average per second, a
    /// page of dense text scrolling at 2400 × 1560 and 3 to 8 Mbps made VideoToolbox drop 5 frames in a row (14 at
    /// 3 Mbps) about ten frames after each periodic keyframe, 83 ms frozen every 2 s (the soak test of 2026-10-10); left
    /// unset, the encoder overshoots the rate the controller asks for by up to 46 % at 2 Mbps, which a link cut to that
    /// rate cannot carry.
    static func dataRateLimit(bitsPerSecond: Int) -> (bytes: Int, seconds: Int) {
        let seconds = keyframeInterval / frameRate
        return (bitsPerSecond * 2 * seconds / 8, seconds)
    }

    /// The next frame `encode` takes is forced to be a keyframe. The request stands until a frame carrying it is
    /// emitted: one that VideoToolbox refuses, fails or drops leaves it for the frame after (one cut short by
    /// `invalidate()` does not, since nothing follows it).
    public func requestKeyframe() { lock.lock(); forceKey = true; lock.unlock() }

    /// True while a keyframe request waits for a frame to carry it: one asked for, or one a frame VideoToolbox failed
    /// or dropped was carrying, which stands for the next frame.
    public var isKeyframeRequested: Bool { lock.withLock { forceKey } }

    public var nextSeq: UInt32 { lock.lock(); defer { lock.unlock() }; return seq }

    /// Returns false when the frame was dropped because two frames are already being encoded, and
    /// also when the encoder was invalidated or VideoToolbox refused the frame (reported to `onError`).
    @discardableResult
    public func encode(_ pixelBuffer: CVPixelBuffer, captureHostTimeNs: UInt64) -> Bool {
        lock.lock()
        guard let session, inFlight < 2 else { lock.unlock(); return false }
        inFlight += 1
        let key = forceKey; forceKey = false
        let n = seq; seq &+= 1
        lock.unlock()

        let pts = CMTime(value: CMTimeValue(captureHostTimeNs / 1000), timescale: 1_000_000)
        let props: CFDictionary? = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: .invalid,
                                                     frameProperties: props, infoFlagsOut: nil) { [weak self] status, flags, sample in
            guard let self else { return }
            let live = self.lock.withLock {
                self.inFlight -= 1
                let live = self.session != nil
                // Failed or dropped: a keyframe request this frame carried stands for the next frame.
                if live, key, status != noErr || sample == nil { self.forceKey = true }
                return live
            }
            if status == noErr, let sample {
                self.emit(sample, seq: n, captureHostTimeNs: captureHostTimeNs, carriesKeyRequest: key)
            } else if !live {
                log.debug("frame \(n) ended by invalidate: \(status)")
            } else if status != noErr {
                self.failures.report(.encode(status), "encode callback, frame \(n)")
            } else {
                // A realtime encoder under load lets frames go: a dropped frame, said at info at most once a second.
                let now = Double(DispatchTime.now().uptimeNanoseconds) / 1e9
                if let count = self.lock.withLock({ self.drops.dropped(now: now) }) {
                    let carried = key ? ", which carried a keyframe request; it stands for the next frame" : ""
                    log.info("VideoToolbox dropped \(count, privacy: .public) frame\(count == 1 ? "" : "s", privacy: .public) since the last line, the last \(n, privacy: .public) (flags \(flags.rawValue, privacy: .public))\(carried, privacy: .public)")
                }
                self.failures.deliver(.frameDropped)
            }
        }
        if status != noErr {
            let live = lock.withLock {
                inFlight -= 1
                let live = self.session != nil
                if live, key { forceKey = true }   // refused: the request stands for the next frame
                return live
            }
            if live {
                failures.report(.encode(status), "encode frame \(n)")
            } else {
                log.debug("frame \(n) refused, encoder invalidated: \(status)")
            }
            return false
        }
        return true
    }

    /// `carriesKeyRequest`: the frame was forced to be a keyframe, so a frame that cannot be emitted leaves the request
    /// standing for the next one, as a failed frame does.
    private func emit(_ sample: CMSampleBuffer, seq: UInt32, captureHostTimeNs: UInt64, carriesKeyRequest: Bool) {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool ?? false
        let isKey = !notSync
        var sets: [Data] = []
        if isKey, let fd = CMSampleBufferGetFormatDescription(sample) { sets = Self.parameterSets(from: fd, codec: codec) }
        func notEmitted(_ error: CodecError, _ context: String) {
            if carriesKeyRequest { lock.withLock { if session != nil { forceKey = true } } }
            failures.report(error, context)
        }
        guard let block = CMSampleBufferGetDataBuffer(sample) else {
            notEmitted(.missingData, "encoded frame \(seq) has no data buffer")
            return
        }
        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { raw -> OSStatus in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        guard status == noErr else { notEmitted(.encode(status), "copy bytes of frame \(seq)"); return }
        onFrame?(EncodedFrame(seq: seq, captureHostTimeNs: captureHostTimeNs, isKey: isKey, data: data,
                              parameterSets: sets, codec: codec, width: width, height: height))
    }

    static func parameterSets(from fd: CMFormatDescription, codec: Codec) -> [Data] {
        var count = 0
        var sets: [Data] = []
        if codec == .hevc {
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>? = nil; var size = 0
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                if let ptr { sets.append(Data(bytes: ptr, count: size)) }
            }
        } else {
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>? = nil; var size = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                if let ptr { sets.append(Data(bytes: ptr, count: size)) }
            }
        }
        return sets
    }

    /// Flushes the frames in flight to `onFrame`, then releases the session. Safe to call while
    /// another thread is encoding; later calls to `encode` return false.
    public func invalidate() {
        let taken: VTCompressionSession? = lock.withLock { defer { session = nil }; return session }
        guard let taken else { return }
        VTCompressionSessionCompleteFrames(taken, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(taken)
    }

    deinit { invalidate() }
}
