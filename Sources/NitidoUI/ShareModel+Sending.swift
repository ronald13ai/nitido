// What goes out to the viewer: every 250 ms the bitrate controller adapts to the link (`adaptToLink`); each encoded
// frame passes spec section 8's dropping rule (`deliver`); after a skip, the drain asks for the keyframe that lets
// the viewer decode again (`keyframeAfterDrain`); and every keyframe forced for the viewer is kept half a second from
// the last (`forceKeyframe`), with a still source's newest frame encoded again to carry it (`sendKeyframe`).

import QuartzCore
import NitidoCore
import NitidoCodec
import NitidoLink
import os

private let log = Logger(subsystem: "ai.ronar.nitido", category: "share")

extension ShareModel {
    /// Every 250 ms while a viewer is connected (`beginSession`): the dropping rule observes the send backlog; the
    /// bitrate controller adapts the encoder's rate to it and to the RTT (spec 8), unless the codec loop holds the
    /// slider's rate; and a drain the rule was waiting for asks for its keyframe.
    func adaptToLink(_ link: NitidoLink.Link, now: CFTimeInterval) {
        // The measure the dropping rule judges, for it and the controller alike: without the keyframe on its way, one
        // burst made on purpose and never congestion by itself; those behind it count.
        let backlog = link.backlogBytesExcludingKeyframes
        backlogPolicy.observe(backlogBytes: backlog, bitsPerSecond: currentBitrate, now: backlogClock())
        let skipped = backlogPolicy.takeTrip()
        if !loopback, let encoder {
            // Spec 8: the RTT p50 of the last second, the strip's own figure, not the latest ping alone, or how long
            // the oldest ping has waited for its pong, if that is longer: pongs held up behind a queue would otherwise
            // leave the last good RTT standing until they came back. A skip the dropping rule started since the last
            // update cuts now, hold or not.
            let rttMs = [snapshot.rttMs, link.oldestUnansweredPingMs(now: now)].compactMap { $0 }.max()
            let bps = controller.update(rttMs: rttMs, backlogBytes: backlog, frameAgeMs: nil,
                                        fps: max(snapshot.captureFPS, 30), now: now, skippedForBacklog: skipped)
            if bps != currentBitrate {
                // For half a second after a cut, the dropping rule judges the backlog at the rate before it, so the cut
                // does not trip a skip, and a second cut, by itself.
                if bps < currentBitrate {
                    backlogPolicy.rateCut(from: currentBitrate, now: backlogClock())
                }
                let rtt = rttMs.map { String(format: "%.1f ms", $0) } ?? "unknown"
                log.info("the bitrate goes from \(Double(self.currentBitrate) / 1e6, format: .fixed(precision: 1), privacy: .public) to \(Double(bps) / 1e6, format: .fixed(precision: 1), privacy: .public) Mbps: send backlog \(backlog, privacy: .public) bytes, RTT \(rtt, privacy: .public)\(skipped ? ", frames skipped for the backlog" : "", privacy: .public)")
                currentBitrate = bps; encoder.setBitrate(bps)
            }
        }
        // A source that went still after the drop sends no frame that could check the drain: this does.
        keyframeAfterDrain(backlog: backlog, now: backlogClock())
    }

    /// An encoded frame for the viewer (`handleEncoded`): a keyframe always goes out, and a delta goes out unless the
    /// viewer is waiting for a keyframe or spec section 8's dropping rule skips it.
    func deliver(_ f: EncodedFrame, to link: NitidoLink.Link, now: CFTimeInterval) {
        // Spec section 8: skip non-key frames once the backlog has stayed over 150 ms worth for 100 ms, or is over a
        // second's worth, then send the next keyframe (`BacklogPolicy`). A delta after a drop refers to frames the
        // viewer never got, so none goes out until it has. The keyframe on its way is left out of the backlog.
        let backlog = link.backlogBytesExcludingKeyframes
        let at = backlogClock()
        if !f.isKey, viewerNeedsKeyframe {
            // The viewer has none of the frames this delta refers to, and its keyframe is on the way (`sendKeyframe`).
            // One encoded before it took over was never going to reach it: not a dropped frame. One encoded after,
            // while the half-second limit holds the keyframe for a viewer that came back, is a frame it never sees.
            if let from = heldFromSeq, f.seq >= from { telemetry.recordDrop(at: now) }
        } else if f.isKey {
            // A keyframe always goes out: it ends a skip (and starts the rule's hold-off) or a takeover's wait.
            backlogPolicy.keyframeSent(now: at)
            viewerNeedsKeyframe = false; heldFromSeq = nil
            keyframeSentAt = now
            send(f, on: link, at: now)
        } else {
            switch backlogPolicy.delta(backlogBytes: backlog, bitsPerSecond: currentBitrate, now: at) {
            case .send:
                send(f, on: link, at: now)
            case .trip(let overFor):
                let worth = Double(backlog) * 8 / Double(currentBitrate) * 1000
                let judged = backlogPolicy.judgedRate(currentBitrate, now: at)
                let why = backlog > BacklogPolicy.ceiling(bitsPerSecond: judged)
                    ? "over a second's worth"
                    : "over \(Int(BacklogPolicy.thresholdSeconds * 1000)) ms worth for \(Int((overFor * 1000).rounded())) ms"
                log.info("send backlog of \(backlog, privacy: .public) bytes, \(worth, format: .fixed(precision: 0), privacy: .public) ms at \(Double(self.currentBitrate) / 1e6, format: .fixed(precision: 1), privacy: .public) Mbps, \(why, privacy: .public); skipping frames until a keyframe")
                telemetry.recordDrop(at: now)
                keyframeAfterDrain(backlog: backlog, now: at)
            case .skip:
                telemetry.recordDrop(at: now)
                keyframeAfterDrain(backlog: backlog, now: at)
            }
        }
    }

    /// A frame that goes to the viewer, with its setup when it carries one; the strip's bitrate counts it.
    private func send(_ f: EncodedFrame, on link: NitidoLink.Link, at now: CFTimeInterval) {
        if let cfg = f.videoConfig { link.send(.videoConfig(cfg)) }
        link.send(.videoFrame(f.videoFrame))
        telemetry.recordBytes(f.data.count, at: now)
    }

    /// After a drop, once the backlog is under one frame's worth: asks for the keyframe that lets the viewer decode
    /// again (`BacklogPolicy.keyframeDue`), within the viewer's half-second limit (`forceKeyframe`). `sendKeyframe`
    /// covers a still source too (it encodes the newest frame again), so the viewer never keeps a damaged or stale
    /// picture until the content moves. Asks again only if no keyframe went out within a second. With no encoder (the
    /// codec loop turned off during the skip took it) `sendKeyframe` makes one from the newest frame, and a fresh
    /// encoder starts with a keyframe: a still source sends no next frame that would. The log line says whether the
    /// keyframe goes now or when the limit lets it, as a tester reads it (docs/testing.md item 19): one held for up to
    /// half a second, logged as sent, looked like the skips the item checks for.
    private func keyframeAfterDrain(backlog: Int, now: CFTimeInterval) {
        guard backlogPolicy.keyframeDue(backlogBytes: backlog, bitsPerSecond: currentBitrate, now: now) else { return }
        let skipped = backlogPolicy.skipped
        let lasted = backlogPolicy.trippedAt.map { (now - $0) * 1000 } ?? 0
        let due: Double?
        switch forceKeyframe() {
        case .now: due = nil
        case .at(let at): due = at
        case .folded: due = forcedKeyframes.dueAt
        }
        let keyframe = due.map { "the keyframe goes when the half-second limit is up (in \(Int((max(0, $0 - CACurrentMediaTime()) * 1000).rounded())) ms)" }
            ?? "sending a keyframe"
        log.info("the send backlog drained after \(skipped, privacy: .public) skipped frames in \(lasted, format: .fixed(precision: 0), privacy: .public) ms; \(keyframe, privacy: .public)")
    }

    /// A keyframe for the viewer, at most one per half second (`KeyframeLimiter`): at once, or when the half second
    /// since the last one forced is up, unless a keyframe has gone out by then. The viewer's asks (`keyframeRequest`)
    /// and the sharer's own (a takeover, the drain after a skip) all come here. A storm of them (the evening two-Mac
    /// test of 2026-10-09) filled the link the drain was meant to clear and made VideoToolbox drop frames. Returns the
    /// limiter's answer, which the drain's log line says.
    @discardableResult
    func forceKeyframe() -> KeyframeLimiter.Answer {
        let now = CACurrentMediaTime()
        let answer = forcedKeyframes.ask(now: now)
        switch answer {
        case .now:
            sendKeyframe()
        case .at(let due):
            let token = forcedKeyframesToken
            Task { [weak self] in
                do { try await Task.sleep(for: .seconds(max(0, due - now))) } catch { return }
                guard let self, token == forcedKeyframesToken else { return }
                if forcedKeyframes.due(now: CACurrentMediaTime(), lastKeyframeAt: keyframeSentAt) { sendKeyframe() }
            }
        case .folded:
            break
        }
        return answer
    }

    /// The viewer the forced keyframes were limited for is gone: the next one starts afresh.
    func forgetForcedKeyframes() {
        forcedKeyframes = KeyframeLimiter(); forcedKeyframesViewer = nil
        forcedKeyframesToken &+= 1; keyframeSentAt = nil
    }

    /// The next frame the viewer gets is a keyframe. A still source sends no next frame (`CaptureSession` forwards only
    /// changed ones), so a viewer that just connected, or lost its decoder, would see nothing until the content moved:
    /// when the encoder takes no frame within `stillAfter` (a frame it turned away at its cap does not count), the
    /// newest one is encoded again (a fresh encoder's first frame is a keyframe, a running one's is after the request).
    /// Forced keyframes come through `forceKeyframe`, which keeps them half a second apart.
    func sendKeyframe() {
        encoder?.requestKeyframe()
        let requestedAt = CACurrentMediaTime()
        Task { [weak self] in
            do { try await Task.sleep(for: .seconds(Self.stillAfter)) } catch { return }
            // A frame the encoder took since the request carried the keyframe; one it turned away at the cap did not.
            guard let self, lastAcceptedAt < requestedAt else { return }
            encodeNewestAgain()
        }
    }
}
