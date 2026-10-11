// The video encoder the share makes for the codec loop and the viewer alike: frames go in (`encode`) at most two at
// a time, and the newest one turned away waits for the next free slot (`encodePendingNewest`); what comes out arrives
// in order through the session's mailbox (`EncoderOutput`, `handleEncoded`); failures and drops are counted, and ten
// failures in a row fail the share with Retry (`handleCodecError`, `failCodec`, `dropCodec`).

import CoreVideo
import VideoToolbox
import QuartzCore
import NitidoCore
import NitidoCodec
import os

private let log = Logger(subsystem: "ai.ronar.nitido", category: "share")

extension ShareModel {
    /// What an encoder hands over: a frame, or a frame it failed, dropped or emitted empty, or a setting it rejected.
    enum EncoderOutput: Sendable { case frame(EncodedFrame), error(CodecError) }

    /// A still source sends no frame (`CaptureSession` forwards only changed ones), so the loop or a viewer would show
    /// nothing until the content changed: the newest raw frame is encoded again. It is stamped now, as it reaches the
    /// encoder, so the capture-to-display figure counts the codec and the display, not how long the source has been still
    /// (which could be seconds, and over five would be logged as the clocks disagreeing). It is not a new capture.
    func encodeNewestAgain() {
        guard loopback || isSending, state == .capturing, let raw = latestRaw else { return }
        encode(raw.pixelBuffer, captureHostTimeNs: UInt64(CACurrentMediaTime() * 1e9))
    }

    /// Hands a frame to the encoder, made (again) for its size; `handleDecoded` shows the result against `latestRaw`.
    func encode(_ pixelBuffer: CVPixelBuffer, captureHostTimeNs: UInt64) {
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        if encoder == nil || encoder?.width != width || encoder?.height != height { makeEncoder(width: width, height: height) }
        guard let encoder else { return }
        let n = encoder.nextSeq
        // The loop's codec time; only a decoded loop frame takes its start back, so a frame for the viewer alone has none.
        if loopback { encodeStarts[n] = CACurrentMediaTime() }
        if encoder.encode(pixelBuffer, captureHostTimeNs: captureHostTimeNs) {
            newestPending = false; lastAcceptedAt = CACurrentMediaTime()
        } else {
            encodeStarts.removeValue(forKey: n)
            // `nextSeq` moves only once the encoder has taken the frame. A refusal after that went to `onError`, which
            // counts it. A frame turned away at the two-in-flight cap is not lost yet: it is encoded as soon as a slot
            // frees (`encodePendingNewest`), and counts as dropped only if a newer frame replaces it first (`ingest`,
            // `dropCodec`). The model never holds an invalidated encoder (`dropCodec` goes with every invalidation), so a
            // refusal here is always the cap.
            if encoder.nextSeq == n { newestPending = true; newestPendingStamp = captureHostTimeNs }
        }
    }

    /// After an encoder output or a frame failure, which frees a slot: the newest frame, turned away at the cap, goes in
    /// now with the stamp it was turned away with: its capture time, or for a still source's frame encoded again, the
    /// time of that encode. Its capture time there would count how long the source had been still, seconds maybe, as
    /// latency. Turned away again, it stays pending for the next one, so nothing builds a queue.
    private func encodePendingNewest() {
        guard newestPending else { return }
        newestPending = false
        let stamp = newestPendingStamp
        newestPendingStamp = nil
        guard loopback || isSending, state == .capturing, let raw = latestRaw else { return }
        encode(raw.pixelBuffer, captureHostTimeNs: stamp ?? raw.captureHostTimeNs)
    }

    func makeEncoder(width: Int, height: Int) {
        // A size change with a viewer connected (or a rebuild after failures) keeps what the controller learnt about the
        // link: the rate scales with the pixel count. A new viewer, or the loop, sets its own (`linkStateChanged`).
        let rebuilding = rebuiltEncoderPixels != nil
        let previousPixels = encoder.map { $0.width * $0.height } ?? rebuiltEncoderPixels
        rebuiltEncoderPixels = nil
        encoder?.invalidate(); decoder?.invalidate(); decoder = nil; decoderConfig = nil
        codecNotice = nil; decodeFailures = 0
        if !rebuilding { encodeFailures = 0 }
        do throws(CodecError) {
            let keepsController = !loopback && isSending && previousPixels != nil
            var rescaled = controller
            let bitsPerSecond = loopback ? Int(qualityMbps * 1_000_000)
                : keepsController ? rescaled.rescale(fromPixels: previousPixels!, toPixels: width * height)
                : BitrateController.initialBitrate(width: width, height: height)
            let e = try VideoEncoder(width: width, height: height, preferred: .hevc, bitsPerSecond: bitsPerSecond)
            // Both through the session's mailbox, in the order they come (`encoderOutput`). `onError` is set before the
            // first encode. It runs on a VideoToolbox queue, or on this thread inside `encode` and `setBitrate`, and a
            // setting rejected inside `init` arrives the moment it is set. The encoder feeds the viewer too, so a frame
            // it fails or drops freezes the viewer's picture as well, and only this tells the sharer.
            let output = encoderOutput
            e.onFrame = { f in output?.yield(.frame(f)) }
            e.onError = { err in output?.yield(.error(err)) }
            encoder = e
            currentBitrate = bitsPerSecond
            controller = keepsController ? rescaled : BitrateController(initial: currentBitrate)
            codecLabel = e.codec == .hevc ? "HEVC" : "H.264"
        } catch {
            log.error("could not create the video encoder: \(String(describing: error), privacy: .public)")
            // The encoder invalidated above goes with the failure: kept, Retry at its size would reuse it, and an
            // invalidated encoder turns every frame away (`encode` would count each as a drop and wait for a slot
            // that never frees).
            dropCodec()
            if case .tooLarge = error {
                // Retry at the same size would fail the same way: the way forward is a smaller picture.
                state = .failed("\(error.plainDescription) Press Retry and pick a smaller window, or choose a scaled mode for the display in System Settings.")
            } else {
                state = .failed("This Mac's hardware video encoder could not start\(error.statusNote); press Retry to try again.")
            }
            endViewers()
        }
    }

    /// Internal, not private, so a test can hand it a frame the decoder cannot read.
    func handleEncoded(_ f: EncodedFrame) {
        let now = CACurrentMediaTime()
        // After this frame has gone out: the slot it freed takes the newest frame, if the cap turned that one away.
        defer { encodePendingNewest() }
        encodeFailures = 0
        // The bitrate figure is what went to the viewer (frames skipped for the backlog add nothing), or with no viewer,
        // what the codec loop's encoder made.
        if !isSending, loopback { telemetry.recordBytes(f.data.count, at: now) }
        if isSending, let link { deliver(f, to: link, now: now) }
        guard loopback else { return }
        decodeForLoop(f, now: now)
    }

    /// Codec failures that are not thrown (Task 9's `onError`); the codec has logged them. A frame the encoder failed
    /// or emitted empty counts in the strip's dropped figure, and ten in a row fail the share with Retry, like the
    /// viewer's ten-failure rule for decoding (Task 14). A frame VideoToolbox dropped is only a dropped frame
    /// (`droppedByEncoder`). A rejected setting is said in a notice over the picture.
    func handleCodecError(_ error: CodecError, from part: String = "encoder") {
        switch error {
        case .frameDropped:
            droppedByEncoder()
        case .encode, .missingData:
            let now = CACurrentMediaTime()
            telemetry.recordDrop(at: now)
            encodeStarts = encodeStarts.filter { now - $0.value < 1 }   // a failed frame never decodes; drop its start
            encodeFailures += 1
            if encodeFailures >= 10 { failCodec("encoder", message: "Video encoding keeps failing."); return }
            // The failed frame freed its slot, as an output does (`handleEncoded`): the newest frame, if the cap turned it
            // away, goes in now; a still source would send no other. A keyframe request it carried stands for the next
            // frame, and over a still source none comes: `sendKeyframe` encodes the newest frame again, as for a frame
            // VideoToolbox dropped (`droppedByEncoder`). Not once the encoder is gone (the loop turned off, a share
            // retired): a late failure from it makes no new one.
            guard let encoder else { return }
            if Self.rebuildsEncoder(after: error, failuresInARow: encodeFailures) {
                log.error("the video encoder failed \(self.encodeFailures, privacy: .public) frames in a row, the last with \(String(describing: error), privacy: .public); making a fresh one")
                rebuildEncoder()
                return
            }
            encodePendingNewest()
            if encoder.isKeyframeRequested { sendKeyframe() }
        case .property(let key, let status):
            codecNotice = "The video \(part) rejected its \(CodecError.settingName(key)) setting (error \(status)); the picture goes on without it."
        case .sessionCreate, .decode, .formatDescription, .prepare, .tooLarge:
            codecNotice = error.plainDescription   // Task 9 throws these instead; shown all the same if one ever arrives
        }
    }

    /// A frame VideoToolbox dropped (`CodecError.frameDropped`): a realtime encoder under load lets frames go, as it
    /// did ten in a row under the keyframe storm of the evening two-Mac test of 2026-10-09, which failed the share. It
    /// is a dropped frame in the strip, and never counts towards the ten failures in a row. Its slot is free, so the
    /// newest frame the cap turned away goes in. A keyframe request it carried stands for the next frame
    /// (`VideoEncoder`), and a still source sends none: `sendKeyframe` encodes the newest frame again if no frame gets
    /// in first. That is the same keyframe asked for again, not another one forced, so the viewer's half-second limit
    /// does not hold it back.
    private func droppedByEncoder() {
        let now = CACurrentMediaTime()
        telemetry.recordDrop(at: now)
        encodeStarts = encodeStarts.filter { now - $0.value < 1 }   // a dropped frame never decodes; drop its start
        // Not once the encoder is gone (the loop turned off, a share retired): a late drop from it makes no new one.
        guard let encoder else { return }
        encodePendingNewest()
        if encoder.isKeyframeRequested { sendKeyframe() }
    }

    /// Whether an encode failure lets the encoder go for a fresh one: every third in a row, as the viewer lets its decoder
    /// go (`ViewModel.decodeFailed`), and at once for a session VideoToolbox no longer runs (invalidated, which a sleep and
    /// wake or a GPU reset can leave behind, or malfunctioning), which fails every frame. Ten in a row still end the share.
    nonisolated static func rebuildsEncoder(after error: CodecError, failuresInARow: Int) -> Bool {
        if case .encode(let status) = error,
           [kVTInvalidSessionErr, kVTVideoEncoderMalfunctionErr, kVTSessionMalfunctionErr].contains(status) { return true }
        return failuresInARow % 3 == 0
    }

    /// Lets a failing encoder go. The next frame makes a fresh one (`encode`), at the same rate for a viewer, with the
    /// failures in a row still counting, and its first frame is a keyframe that carries the setup; over a still source
    /// `sendKeyframe` encodes the newest frame again to make it. VideoToolbox reports nothing more from the one let go.
    private func rebuildEncoder() {
        rebuiltEncoderPixels = encoder.map { $0.width * $0.height }
        encoder?.invalidate(); encoder = nil
        encodePendingNewest()
        sendKeyframe()
    }

    /// The encoder or the decoder (`part`) is not coming back by itself: stop both, keep the raw picture, offer Retry
    /// (a fresh session and encoder).
    func failCodec(_ part: String, message: String) {
        log.error("the video \(part, privacy: .public) failed 10 frames in a row")
        dropCodec()
        state = .failed(message)
        endViewers()
    }

    /// Lets the encoder and the decoder go, with their counts and figures: the next frame to encode makes a fresh
    /// encoder (`encode`), which starts with a keyframe.
    func dropCodec() {
        // A frame still waiting for a slot never reaches an encoder now.
        if newestPending { telemetry.recordDrop(at: CACurrentMediaTime()) }
        encoder?.invalidate(); decoder?.invalidate(); encoder = nil; decoder = nil; decoderConfig = nil
        encodeFailures = 0; decodeFailures = 0; codecLabel = "raw"; codecMs = nil; encodeStarts.removeAll(); newestPending = false
        newestPendingStamp = nil; rebuiltEncoderPixels = nil
    }
}
