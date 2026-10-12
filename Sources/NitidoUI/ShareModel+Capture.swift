// The share's capture session: what the model needs from one (`CaptureSource`), the picker each attempt opens
// (`start`, `retry`), the loops a session runs (`beginSession`), the frames and events it hands over (`ingest`,
// `handle`), and its stop, queued behind every earlier stop since the system picker is one per process
// (`retireSession`, `stop`).

import CoreGraphics
import QuartzCore
import NitidoCore
import NitidoCapture
import NitidoCodec
import NitidoLink
import os

private let log = Logger(subsystem: "ai.ronar.nitido", category: "share")

/// What `ShareModel` needs from a capture session. `CaptureSession` is the real one; tests use a fake.
@MainActor
protocol CaptureSource: AnyObject {
    var frames: AsyncStream<CapturedFrame> { get }
    var events: AsyncStream<CaptureEvent> { get }
    func presentPicker(excludingWindowIDs: [CGWindowID])
    func stop() async
    /// Frames the source let go before the share took them, since the last call (`CaptureSession.takeDroppedFrames`).
    func takeDroppedFrames() -> Int
}

extension CaptureSource {
    func takeDroppedFrames() -> Int { 0 }
}

extension CaptureSession: CaptureSource {}

extension ShareModel {
    /// Shows the system picker. Ignored while picking or capturing; after a cancel or a failure it stops
    /// the old session first and starts a fresh one, so a second Share never leaves a session behind.
    public func start(excludingWindowIDs: [CGWindowID]) {
        if case .picking = state { return }
        if case .capturing = state { return }
        excludedWindowIDs = excludingWindowIDs
        // VideoToolbox loads its codecs while the person picks, not on the main actor as the first viewer connects; Core
        // Image compiles its kernels then too, not as the first frame is drawn.
        CodecWarmUp.start()
        ImageWarmUp.start()
        failureNeedsPermission = false
        failureStoppedFromMenuBar = false
        renderFailure = nil
        mayAskForScreenRecording = !screenRecordingGranted()
        state = .picking
        attempt &+= 1
        let current = attempt
        retireSession()
        guard let earlier = Self.retiring else { beginSession(); return }
        Task { [weak self] in
            await earlier.value
            guard let self, attempt == current, state == .picking else { return }
            beginSession()
        }
    }

    /// After a failure: stops the old session and shows the picker again with the same windows excluded.
    public func retry() {
        guard case .failed = state else { return }
        start(excludingWindowIDs: excludedWindowIDs)
    }

    /// Stops capture. Returns once this model's sessions, and every session retired before them, have stopped.
    public func stop() async {
        attempt &+= 1
        retireSession()
        // Idle at once: the loops are cancelled and the session is queued to stop, so a start that lands
        // while this waits proceeds (behind the stop) instead of being ignored or reset to idle afterwards.
        state = .idle
        await Self.retiring?.value
    }

    private func beginSession() {
        let session = makeSource()
        capture = session
        // At most two frames are in flight at the encoder, so the mailbox never holds more than a few.
        let (outputs, output) = AsyncStream<EncoderOutput>.makeStream(bufferingPolicy: .unbounded)
        encoderOutput?.finish(); encoderOutput = output
        // The loops hold the model weakly: a session's streams never finish on their own, so a strong
        // reference here would keep every model alive for as long as the process runs.
        tasks = [
            Task { [weak self] in
                for await event in outputs {
                    guard let self else { return }
                    switch event {
                    case .frame(let f): handleEncoded(f)
                    case .error(let error): handleCodecError(error)
                    }
                }
            },
            Task { [weak self] in
                for await event in session.events {
                    guard let self else { return }
                    handle(event)
                }
            },
            Task { [weak self] in
                for await frame in session.frames {
                    guard let self else { return }
                    ingest(frame)
                }
            },
            Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard let self else { return }
                    let now = CACurrentMediaTime()
                    refreshSnapshot(now: now)
                    if isSending, let link { adaptToLink(link, now: now) }
                    codecMs = loopback ? codecWindow.stats(now: now)?.p50 : nil
                }
            },
        ]
        session.presentPicker(excludingWindowIDs: excludedWindowIDs)
    }

    /// Cancels the current session's loops and queues its stop behind every earlier one.
    private func retireSession() {
        tasks.forEach { $0.cancel() }
        tasks = []
        encoderOutput?.finish(); encoderOutput = nil
        // The viewer is told `bye` now; a stop returns only once it is out (`stop` waits for `retiring`), so a quit
        // does not cut it off.
        let byeSent = link.map { viewer in Task { await viewer.closeAndWait() } }
        link = nil; advertiser?.stop(); advertiser = nil; linkTasks.forEach { $0.cancel() }; linkTasks = []; isSending = false; viewerName = nil
        viewerReconnecting = false; reconnectGraceToken &+= 1; viewerNeedsKeyframe = false; heldFromSeq = nil
        forgetForcedKeyframes()
        unpaired.values.forEach { $0.link.close(); $0.states.cancel() }; unpaired = [:]
        listeningPort = nil; networkNotice = nil; advertisedName = nil; viewerNotice = nil
        loopback = false
        // A new session never inherits an encoder, whether or not the loop was on: the next frame makes a fresh one.
        dropCodec()
        qualityRestToken &+= 1
        // The view keeps the last frame for redraws; hand it back so the old stream's buffer pool can drain. The model
        // lets go of the same frame, and a new session never encodes the old one.
        sink.releaseHeldFrame()
        latestRaw = nil; newestPending = false
        let old = capture
        capture = nil
        guard old != nil || byeSent != nil else { return }
        let earlier = Self.retiring
        Self.retiring = Task { @MainActor in
            await earlier?.value
            await old?.stop()
            await byeSent?.value
        }
    }

    private func ingest(_ frame: CapturedFrame) {
        telemetry.recordCapture(at: Double(frame.captureHostTimeNs) / 1e9)
        lastCaptureAt = CACurrentMediaTime()
        // The frame the cap turned away, still waiting for a slot, is replaced by this one and never reaches the encoder:
        // only now is it dropped (`encode`).
        if newestPending { telemetry.recordDrop(at: lastCaptureAt); newestPending = false }
        latestRaw = frame
        // Encode for the loop or a viewer, and only while capturing: after a failure (the encoder's included) the raw
        // picture goes on until Retry, and no encoder is made again for every frame. The sharer sees the raw picture
        // unless the loop shows the decoded one.
        let encoding = (loopback || isSending) && state == .capturing
        if !(loopback && encoding) { sink.push(frame.pixelBuffer, captureHostTimeNs: frame.captureHostTimeNs) }
        guard encoding else { return }
        encode(frame.pixelBuffer, captureHostTimeNs: frame.captureHostTimeNs)
    }

    private func handle(_ event: CaptureEvent) {
        switch event {
        case .started(let w, let h, let s):
            // Also mid-share: another pick, a window resized, a display mode changed (`CaptureSession`). The encoder is
            // made again for the new buffer size (`encode`), and its keyframe carries the new setup; the hello says the
            // new size and scale to the viewer and to every viewer that pairs from now on.
            let resized = state == .capturing && (pixelSize != CGSize(width: w, height: h) || scale != s)
            pixelSize = CGSize(width: w, height: h); scale = s
            if case .failed = state {
                // A codec or listener failure leaves the stream, and the raw picture, running until Retry: a new size
                // from it resizes the picture and the failure stays.
                guard captureFailed else {
                    log.info("the failed share's capture is now \(w, privacy: .public)×\(h, privacy: .public); waiting for Retry")
                    return
                }
                // The capture had ended, and a new pick from the session's picker started it again: the share resumes as
                // a fresh one. The card goes, the next frame makes a new encoder, and the listener starts again below.
                log.info("the capture started again at \(w, privacy: .public)×\(h, privacy: .public) after it ended; the share resumes")
                dropCodec()
                failureNeedsPermission = false; failureStoppedFromMenuBar = false; codecNotice = nil
            }
            captureFailed = false
            state = .capturing
            if resized {
                log.info("the capture is now \(w, privacy: .public)×\(h, privacy: .public) @\(s, privacy: .public)x")
                advertiser?.update(hello: hello)
                link?.send(.hello(hello))
            }
            startAdvertising()
        case .cancelled:
            // Only the first pick's cancel goes back to Welcome (spec 12).
            switch state {
            case .picking:
                state = .idle
                onCancelled?()
            case .capturing:
                // The system's "change shared content" picker can open over a live share; cancelling it keeps the
                // current content.
                log.info("A picker was cancelled while capturing; the shared content stays")
            case .failed:
                // The capture ended (Stop Sharing in the menu bar) and the picker that could resume it was cancelled:
                // the Share window keeps offering Retry (spec 12), rather than going back to Welcome.
                log.info("The picker was cancelled after the capture ended; the failure stays")
            case .idle:
                break
            }
        case .stopped:
            state = .idle
        case .failed(let failure):
            // What ScreenCaptureKit said goes to the log; the card says what happened in plain words (spec 9 and 12).
            log.error("the capture failed: \(failure.detail, privacy: .public)")
            // Before the first frame, a missing Screen Recording grant is the likely cause.
            failureNeedsPermission = failure.reason == .notPermitted || state != .capturing && !screenRecordingGranted()
            failureStoppedFromMenuBar = failure.reason == .stoppedFromMenuBar && !failureNeedsPermission
            state = .failed(Self.plainMessage(for: failure, needsPermission: failureNeedsPermission))
            captureFailed = true
            endViewers()
        }
    }

    /// The failure card's sentence for a capture that failed. With `needsPermission` the card adds the fix and offers
    /// System Settings (`ShareView`).
    static func plainMessage(for failure: CaptureFailure, needsPermission: Bool) -> String {
        if needsPermission { return "Nítido is not allowed to record the screen." }
        switch failure.reason {
        case .notPermitted: return "Nítido is not allowed to record the screen."
        case .stoppedFromMenuBar: return "Sharing was stopped from the menu bar. Press Retry to share again."
        case .other: return "The screen capture stopped. Press Retry to share again."
        }
    }
}
