import Foundation
import VideoToolbox
import CoreVideo
import os

private let log = Logger(subsystem: "ai.ronar.nitido", category: "codec")

/// VideoToolbox's first session in a process takes far longer to make than the next ones, while its codecs load: on
/// this Mac a hardware HEVC encoder took 84 ms, then 1.9 ms; a decoder 38 ms, then 3.4 ms (2026-10-12). The share makes
/// its encoder on the main actor as a viewer connects, and the viewer its decoder as the first keyframe comes, so the
/// first of each stalled the main thread (its frame pacer, and the connect moment's animations) by that long. `start`
/// makes and lets go of a small encoder, and of a decoder for the one frame it encodes, once per process and off the main
/// thread, while the person is still picking what to share or typing the code.
public enum CodecWarmUp {
    private static let started = OSAllocatedUnfairLock(initialState: false)

    /// Starts the warm-up on a background queue, the first time it is called in the process; does nothing after. True
    /// when this call started it.
    @discardableResult
    public static func start() -> Bool {
        let first = started.withLock { was -> Bool in
            defer { was = true }
            return !was
        }
        guard first else { return false }
        DispatchQueue.global(qos: .utility).async { warm() }
        return true
    }

    /// Holds what the encoder's handler hands over, for the thread that waits for it.
    private final class Encoded: @unchecked Sendable {
        var sample: CMSampleBuffer?
    }

    static func warm() {
        let width: Int32 = 320, height: Int32 = 180
        var encoder: VTCompressionSession?
        let spec = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary
        let made = VTCompressionSessionCreate(allocator: nil, width: width, height: height, codecType: kCMVideoCodecType_HEVC,
                                              encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                              outputCallback: nil, refcon: nil, compressionSessionOut: &encoder)
        guard made == noErr, let encoder else { log.info("codec warm-up: no encoder (\(made))"); return }
        defer { VTCompressionSessionInvalidate(encoder) }
        var buffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, Int(width), Int(height), kCVPixelFormatType_32BGRA, attrs, &buffer) == kCVReturnSuccess,
              let buffer else { return }
        let encoded = Encoded()
        VTCompressionSessionEncodeFrame(encoder, imageBuffer: buffer, presentationTimeStamp: .zero, duration: .invalid,
                                        frameProperties: nil, infoFlagsOut: nil) { status, _, sample in
            if status == noErr { encoded.sample = sample }
        }
        VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid)
        guard let sample = encoded.sample, let format = CMSampleBufferGetFormatDescription(sample) else { return }
        var decoder: VTDecompressionSession?
        let out = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] as CFDictionary
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                           imageBufferAttributes: out, outputCallback: nil, decompressionSessionOut: &decoder) == noErr,
              let decoder else { return }
        VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { _, _, _, _, _ in }
        VTDecompressionSessionWaitForAsynchronousFrames(decoder)
        VTDecompressionSessionInvalidate(decoder)
    }
}
