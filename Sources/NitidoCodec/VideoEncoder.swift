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

/// Realtime hardware encoder. Thread-safe; `onFrame` is called on a VideoToolbox queue.
public final class VideoEncoder: @unchecked Sendable {
    public let codec: Codec
    public let width: Int
    public let height: Int
    public var onFrame: (@Sendable (EncodedFrame) -> Void)?

    private var session: VTCompressionSession?
    private let lock = NSLock()
    private var seq: UInt32 = 0
    private var forceKey = true
    private var inFlight = 0

    public init(width: Int, height: Int, preferred: Codec = .hevc, bitsPerSecond: Int) throws {
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
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: chosen == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 120 as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanFalse)
        setBitrate(bitsPerSecond)
        VTCompressionSessionPrepareToEncodeFrames(s)
    }

    public func setBitrate(_ bitsPerSecond: Int) {
        guard let session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitsPerSecond as CFNumber)
        let limits = [bitsPerSecond * 3 / 2 / 8, 1] as CFArray   // bytes per one-second window
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits)
    }

    public func requestKeyframe() { lock.lock(); forceKey = true; lock.unlock() }

    /// Returns false when the frame was dropped because two frames are already being encoded.
    @discardableResult
    public func encode(_ pixelBuffer: CVPixelBuffer, captureHostTimeNs: UInt64) -> Bool {
        guard let session else { return false }
        lock.lock()
        guard inFlight < 2 else { lock.unlock(); return false }
        inFlight += 1
        let key = forceKey; forceKey = false
        let n = seq; seq &+= 1
        lock.unlock()

        let pts = CMTime(value: CMTimeValue(captureHostTimeNs / 1000), timescale: 1_000_000)
        let props: CFDictionary? = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: .invalid,
                                                     frameProperties: props, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard let self else { return }
            self.lock.lock(); self.inFlight -= 1; self.lock.unlock()
            guard status == noErr, let sample else { log.error("encode callback: \(status)"); return }
            self.emit(sample, seq: n, captureHostTimeNs: captureHostTimeNs)
        }
        if status != noErr {
            lock.lock(); inFlight -= 1; lock.unlock()
            log.error("encode: \(status)")
            return false
        }
        return true
    }

    private func emit(_ sample: CMSampleBuffer, seq: UInt32, captureHostTimeNs: UInt64) {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool ?? false
        let isKey = !notSync
        var sets: [Data] = []
        if isKey, let fd = CMSampleBufferGetFormatDescription(sample) { sets = Self.parameterSets(from: fd, codec: codec) }
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { raw -> OSStatus in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        guard status == noErr else { log.error("copy bytes: \(status)"); return }
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

    public func invalidate() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }

    deinit { invalidate() }
}
