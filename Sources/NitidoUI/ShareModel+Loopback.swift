// The codec loop (Codec Loop, ⌘L): the sharer's own picture encoded, decoded and shown against the raw frame, split
// at the divider. This file owns the loop's decoder and its failures (`decodeForLoop`, `loopDecodeFailed`), turning
// the loop on and off (`loopbackDidChange`), and the quality slider, whose change a still picture shows once the
// slider rests (`qualityRested`).

import CoreVideo
import QuartzCore
import NitidoCore
import NitidoCodec
import os

private let log = Logger(subsystem: "ai.ronar.nitido", category: "share")

extension ShareModel {
    /// An encoded frame for the codec loop (`handleEncoded`): each new setup makes a fresh decoder, and a decoder that
    /// falls behind skips to the next keyframe. Its pictures come back through `handleDecoded`.
    func decodeForLoop(_ f: EncodedFrame, now: CFTimeInterval) {
        if let cfg = f.videoConfig, cfg != decoderConfig {
            let d: VideoDecoder
            do throws(CodecError) {
                d = try VideoDecoder(config: cfg)
            } catch {
                log.error("could not create the video decoder: \(String(describing: error), privacy: .public)")
                state = .failed("The video decoder could not start\(error.statusNote); press Retry to try again."); endViewers(); return
            }
            decoder?.invalidate()
            decoder = d; decoderConfig = cfg
            // The decoder works on its own queue. Its pictures, failures and superseded frames reach the main actor in
            // decode order through an outbox where only the newest picture waits (`DecoderOutbox`), as on the viewer.
            DecoderOutbox { [weak self, weak d] output in
                guard let self, let d else { return }
                loopDecoderOutput(output, from: d)
            }.attach(to: d)
            d.onError = { [weak self] err in Task { @MainActor in self?.handleCodecError(err, from: "decoder") } }
        }
        guard let decoder else {
            // A decode error let the decoder go, and only a keyframe's setup makes the next one. The keyframe asked for
            // may never come out (the encoder failed or dropped it), so every delta until then asks again: it only
            // sets a flag, and the loop never waits for the periodic keyframe, or forever over a still source.
            if !f.isKey { askForLoopKeyframe() }
            return
        }
        let result = decoder.submit(f.videoFrame)
        guard result != .queued else { return }
        // The decoder has fallen behind: this frame and every delta up to the next keyframe are dropped, and that
        // keyframe drops the frames still waiting (`loopSuperseded`). The first one asks for that keyframe; a later one
        // asks again once a second has passed.
        telemetry.recordDrop(at: now)
        encodeStarts.removeValue(forKey: f.seq)   // this frame never decodes
        if case .fellBehind(let backlog) = result {
            log.info("the codec loop's decoder fell behind with \(backlog.frames, privacy: .public) frames waiting, the oldest for \(backlog.oldestWait * 1000, format: .fixed(precision: 1), privacy: .public) ms; skipping to the next keyframe")
            loopKeyframeAskedAt = now
            askForLoopKeyframe()
        } else if loopKeyframeAskedAt.map({ now - $0 >= 1 }) ?? true {
            loopKeyframeAskedAt = now
            askForLoopKeyframe()
        }
    }

    /// What the loop's decoder handed over (`DecoderOutbox`), in decode order.
    private func loopDecoderOutput(_ output: DecoderOutbox.Output, from d: VideoDecoder) {
        switch output {
        case .frame(let frame): handleDecoded(frame, by: d)
        case .replaced(let seq): loopReplaced(seq, by: d)
        case .decodeFailure(let seq, let error): loopDecodeFailed(d, seq: seq, error: error)
        case .superseded(let seq): loopSuperseded(seq, by: d)
        }
    }

    /// A loop picture a newer one replaced before the main actor took it (`DecoderOutbox`): it was decoded, so the
    /// failure count starts again, as for a picture shown, but it never reaches the screen, so it counts as dropped (a
    /// pause while the view cannot show frames, `FrameSink.dropped`) and its encode start goes. A decoder let go
    /// already, or a loop turned off, says nothing.
    private func loopReplaced(_ seq: UInt32, by d: VideoDecoder) {
        guard d === decoder else { return }
        decodeFailures = 0
        encodeStarts.removeValue(forKey: seq)
        guard loopback, state == .capturing else { return }
        sink.dropped(.replaced)
    }

    /// A frame a later keyframe superseded before the loop's decoder reached it (`VideoDecoder.onSuperseded`): it never
    /// reaches the screen, so it counts as dropped. A decoder let go already says nothing about the current one.
    private func loopSuperseded(_ seq: UInt32, by d: VideoDecoder) {
        guard d === decoder else { return }
        telemetry.recordDrop(at: CACurrentMediaTime())
        encodeStarts.removeValue(forKey: seq)   // this frame never decodes
    }

    /// A frame the loop's decoder could not read (`VideoDecoder.onDecodeFailure`, which logged it). While the loop is on
    /// only decoded frames reach the screen, so a decoder that keeps failing freezes the picture: the decoder is let
    /// go, the encoder asked for a keyframe (whose setup makes a fresh decoder), and ten in a row fail the share with
    /// Retry, like the encoder (and the viewer's rule, `ViewModel.decodeFailed`). A decoder let go already says nothing
    /// about the current one.
    private func loopDecodeFailed(_ d: VideoDecoder, seq: UInt32, error: CodecError) {
        guard d === decoder else { return }
        telemetry.recordDrop(at: CACurrentMediaTime())
        encodeStarts.removeValue(forKey: seq)   // this frame never decodes
        d.invalidate(); decoder = nil; decoderConfig = nil
        decodeFailures += 1
        if decodeFailures >= 10 { failCodec("decoder", message: "Video decoding keeps failing."); return }
        askForLoopKeyframe()
    }

    /// A picture from the loop's decoder, in decode order.
    private func handleDecoded(_ d: DecodedFrame, by source: VideoDecoder) {
        // A decoder let go since (the loop off, a failure, a new setup) shows nothing more.
        guard source === decoder else { return }
        decodeFailures = 0
        // A frame decoded after the loop was turned off (or the share failed) would put the comparison back on
        // screen, and a still source would leave it there: the raw picture already took its place.
        guard loopback, state == .capturing else { return }
        if let start = encodeStarts.removeValue(forKey: d.seq) { codecWindow.add((CACurrentMediaTime() - start) * 1000, at: CACurrentMediaTime()) }
        if encodeStarts.count > 120 { encodeStarts.removeAll() }
        sink.push(d.pixelBuffer, captureHostTimeNs: d.captureHostTimeNs, compareWith: latestRaw?.pixelBuffer, dividerAt: dividerPosition,
                  pictureSize: CGSize(width: d.width, height: d.height))
    }

    func loopbackDidChange() {
        guard !loopback else {
            // An encoder made for a viewer runs at the controller's rate, which the loop freezes: the loop runs at the
            // slider's instead (spec 8), from a new encoder, since a running one's rate control would carry the old
            // rate's quality over many frames (`qualityRested`). The viewer gets the new encoder's keyframe.
            if let encoder, currentBitrate != Int(qualityMbps * 1_000_000), state == .capturing {
                makeEncoder(width: encoder.width, height: encoder.height)
            }
            // On at once: a still source sends no frame to start the loop with, so the one on screen is encoded now.
            encodeNewestAgain()
            return
        }
        qualityRestToken &+= 1
        encoder?.invalidate(); decoder?.invalidate(); encoder = nil; decoder = nil; decoderConfig = nil
        codecLabel = "raw"; codecMs = nil; encodeStarts.removeAll(); codecNotice = nil; encodeFailures = 0; decodeFailures = 0
        // A frame that waited for the loop's encoder is on screen raw now: not a dropped frame.
        newestPending = false
        // Back to raw at once: a still source sends no new frame to replace the comparison on screen. The view keeps
        // the raw frame for redraws, the same one `latestRaw` holds, so turning the loop on again can encode it.
        if let raw = latestRaw { sink.endComparison(showing: raw.pixelBuffer, captureHostTimeNs: raw.captureHostTimeNs) }
    }

    /// How long the quality slider rests before a still picture is encoded again at the new quality (`qualityRested`).
    static let qualityRest: Duration = .milliseconds(150)
    /// No frame for this long means the source is still, or too slow to show a quality change soon.
    static let stillAfter: CFTimeInterval = 0.05

    /// The encoder takes the new rate at once (a rate it rejects comes back through `onError` as a notice), and a
    /// moving source's next frames show it. A still source sends none, so once the slider rests `qualityRested` does.
    func qualityDidChange() {
        guard let encoder else { return }
        // The backlog rule sizes a frame at the rate the encoder runs at (`frameBytes`).
        currentBitrate = Int(qualityMbps * 1_000_000)
        encoder.setBitrate(currentBitrate)
        qualityRestToken &+= 1
        let token = qualityRestToken
        Task { [weak self] in
            do { try await Task.sleep(for: Self.qualityRest) } catch { return }
            guard let self, token == qualityRestToken else { return }
            qualityRested()
        }
    }

    /// A still source sends no frame to show a quality change, so its newest frame is encoded again, as a keyframe
    /// from an encoder made at the new rate: that is the picture a viewer joining at this quality gets. A keyframe from
    /// the running encoder would barely change: its rate control carries the old rate's quality over and moves away
    /// from it only over many frames (60 then 2 Mbps gave a 2 Mbps keyframe as sharp as the 60 Mbps one). Once per
    /// rest, not once per slider step. The new encoder is made here, on the main actor (a hardware session and its
    /// prepare): that happens once per rest and only over a still source, where nothing moves that it could delay.
    ///
    /// With a viewer connected the encoder feeds it too, and a new encoder's keyframe at every rest would reach it faster
    /// than its half-second limit allows (spec 8: keyframes fill the link they should clear). Then the running encoder's
    /// keyframe is forced through that limit instead (`forceKeyframe`): the loop's still picture takes the new rate as
    /// the encoder's rate control moves to it, within a few frames of the content moving.
    private func qualityRested() {
        guard loopback, state == .capturing, encoder != nil, let raw = latestRaw,
              CACurrentMediaTime() - lastCaptureAt >= Self.stillAfter else { return }
        guard !isSending else { forceKeyframe(); return }
        makeEncoder(width: CVPixelBufferGetWidth(raw.pixelBuffer), height: CVPixelBufferGetHeight(raw.pixelBuffer))
        encodeNewestAgain()
    }

    /// The loop's decoder needs a keyframe (it fell behind, failed a frame, or was let go). With a viewer connected the
    /// encoder feeds it too, so the keyframe goes through the viewer's half-second limit (`forceKeyframe`) like every
    /// other forced one; with none, it is asked for at once.
    private func askForLoopKeyframe() {
        guard isSending else { encoder?.requestKeyframe(); return }
        forceKeyframe()
    }
}
