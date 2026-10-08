import SwiftUI
import AppKit
import QuartzCore
import NitidoCore
import NitidoCapture
import NitidoCodec
import NitidoLink
import CoreVideo
import os

private let log = Logger(subsystem: "ai.ronar.nitido", category: "share")

/// What `ShareModel` needs from a capture session. `CaptureSession` is the real one; tests use a fake.
@MainActor
protocol CaptureSource: AnyObject {
    var frames: AsyncStream<CapturedFrame> { get }
    var events: AsyncStream<CaptureEvent> { get }
    func presentPicker(excludingWindowIDs: [CGWindowID])
    func stop() async
}

extension CaptureSession: CaptureSource {}

@MainActor @Observable
public final class ShareModel {
    public enum State: Equatable { case idle, picking, capturing, failed(String) }

    public private(set) var state: State = .idle
    public private(set) var snapshot: Snapshot = .empty
    public private(set) var pixelSize: CGSize = .zero
    public private(set) var scale: CGFloat = 2
    public var showTelemetry = true
    public let sink = FrameSink()
    public let ink = InkController(role: .share)
    /// Rotates after three failed handshakes (`rotateCode`).
    public private(set) var code = Pairing.makeCode()
    public let name = Host.current().localizedName ?? "Mac"
    /// True when the current failure most likely comes from a missing Screen Recording grant, so System Settings is the fix.
    public private(set) var failureNeedsPermission = false
    /// The last reason a frame could not be rendered; cleared by the next frame that reaches the screen.
    public private(set) var renderFailure: String?
    /// True when Screen Recording was not granted as the picker opened, so the picker screen explains the
    /// system prompt that may follow the pick before macOS shows it.
    public private(set) var mayAskForScreenRecording = false

    public var loopback = false { didSet { if loopback != oldValue { loopbackDidChange() } } }
    public var qualityMbps: Double = 20 { didSet { qualityDidChange() } }
    /// Where the comparison splits (0...1). Every decoded frame carries it (`handleDecoded`); a move also reaches the
    /// frame the view keeps, which is drawn again only when the source is still (`FramePacer.moveDivider`).
    public var dividerPosition: Double = 0.5 { didSet { if dividerPosition != oldValue { sink.moveDivider(to: dividerPosition) } } }
    public private(set) var codecMs: Double?
    public private(set) var codecLabel = "raw"
    private var encoder: VideoEncoder?
    private var decoder: VideoDecoder?
    private var decoderConfig: VideoConfig?
    /// The newest captured frame, raw: the left of the comparison while the loop is on. While it is off it is the frame
    /// the view holds (it was pushed raw), so it pins no buffer of its own; turning the loop on encodes it at once,
    /// since a still source sends no frame to start with (`encodeNewestAgain`). Cleared with the session.
    private var latestRaw: CapturedFrame?
    /// When the newest frame came (`CACurrentMediaTime`): a still source sends none.
    @ObservationIgnored private var lastCaptureAt: CFTimeInterval = 0
    /// Bumped by every quality change, loop off and retire, so a pending `qualityRested` for an earlier one does nothing.
    @ObservationIgnored private var qualityRestToken: UInt64 = 0
    private var encodeStarts: [UInt32: Double] = [:]
    private var codecWindow = RollingWindow(seconds: 1)
    /// A codec setting VideoToolbox rejected (`CodecError.property` through `onError`), shown over the picture.
    public private(set) var codecNotice: String?
    /// Frames the encoder failed, dropped or emitted empty in a row; ten fail the share (`handleCodecError`).
    private var encodeFailures = 0
    /// Frames the decoder threw on in a row; ten fail the share (`handleEncoded`). Only a frame decoded resets it.
    private var decodeFailures = 0

    public private(set) var viewerName: String?
    public private(set) var isSending = false
    /// Why viewers cannot reach this Mac right now (the listener is waiting), shown over the picture.
    public private(set) var networkNotice: String?
    /// Internal, not private, so a test can drive the listener's states.
    private(set) var advertiser: Advertiser?
    /// The port the listener bound, once it is ready (logged; tests connect to it directly).
    @ObservationIgnored private(set) var listeningPort: UInt16?
    /// The viewer: a connection that proved the code. Only it is sent to and heard from. Internal, not private, so a
    /// test can congest it.
    private(set) var link: NitidoLink.Link?
    private var linkTasks: [Task<Void, Never>] = []
    /// Connections the listener took that have not proved the code yet, each with the loop that follows its states
    /// (`attach`). Until one does, it may be anybody on the network, so it never touches the viewer.
    private var unpaired: [ObjectIdentifier: (link: NitidoLink.Link, states: Task<Void, Never>)] = [:]
    /// How many connections are still proving the code (tests check that none is left behind).
    var unpairedCount: Int { unpaired.count }
    /// Adapts the viewer's bitrate every 250 ms (the snapshot loop), from the RTT and the send backlog.
    private var controller = BitrateController(initial: 20_000_000)
    /// The encoder's rate, which also sizes a frame for the backlog dropping rule (`handleEncoded`).
    private var currentBitrate = 20_000_000
    /// One frame's worth of bytes at the current rate: the unit of the backlog dropping rule. Internal for tests.
    var frameBytes: Int { currentBitrate / 8 / 60 }
    /// Frames were dropped for the backlog, so the viewer lacks the frames the next deltas refer to: every non-key frame
    /// is skipped until a keyframe goes out, asked for once the backlog drains under one frame (`keyframeAfterDrain`).
    private var needKeyAfterDrain = false
    /// When `keyframeAfterDrain` last asked for that keyframe, so it asks again only if none came within a second.
    @ObservationIgnored private var drainKeyRequestedAt: CFTimeInterval?
    /// Connections that failed before they proved the code; three rotate it.
    private var failedHandshakes = 0

    private var hello: Hello {
        Hello(protocolVersion: protocolVersion, role: .share, name: name,
              pixelWidth: UInt16(min(pixelSize.width, 65535)), pixelHeight: UInt16(min(pixelSize.height, 65535)), scale: Float(scale))
    }

    private let makeSource: @MainActor () -> any CaptureSource
    /// `CGPreflightScreenCaptureAccess` in the app; tests pass a fixed answer.
    private let screenRecordingGranted: @MainActor () -> Bool
    /// The session of the current attempt. Each attempt gets a fresh one: a session's streams end for good
    /// once a task iterating them is cancelled, so a retired session is never reused.
    private var capture: (any CaptureSource)?
    private var excludedWindowIDs: [CGWindowID] = []
    private var telemetry = Telemetry(now: CACurrentMediaTime())
    /// A negative or huge latency was logged once already for this model.
    @ObservationIgnored private var reportedClockMismatch = false
    private var tasks: [Task<Void, Never>] = []
    /// Bumped by every start and stop, so a start that waited for an earlier stop knows when it was superseded.
    private var attempt: UInt64 = 0
    /// Stops of retired sessions, chained in order across every ShareModel. `SCContentSharingPicker.shared`
    /// is one per process, so a new session waits for all of them before it touches the picker; otherwise
    /// a late stop would deactivate the new session's picker or leave an old observer starting streams.
    private static var retiring: Task<Void, Never>?

    public convenience init() { self.init(makeSource: { CaptureSession() }) }

    init(makeSource: @escaping @MainActor () -> any CaptureSource,
         screenRecordingGranted: @escaping @MainActor () -> Bool = { CGPreflightScreenCaptureAccess() }) {
        self.makeSource = makeSource
        self.screenRecordingGranted = screenRecordingGranted
        ink.onOutgoing = { [weak self] m in self?.link?.send(m) }
        sink.onPresented = { [weak self] captureNs, presentedAt in
            guard let self else { return }
            let latencyMs = (presentedAt - Double(captureNs) / 1e9) * 1000
            telemetry.recordDisplay(at: presentedAt)
            telemetry.recordLatency(ms: latencyMs, at: presentedAt)
            if latencyMs < 0 || latencyMs > 5_000, !reportedClockMismatch {
                // The strip shows the figure as it is; the log says what it means.
                reportedClockMismatch = true
                log.error("Capture and display clocks disagree: a frame shows \(latencyMs, format: .fixed(precision: 1), privacy: .public) ms after its capture time")
            }
            if renderFailure != nil { renderFailure = nil }
        }
        sink.onDropped = { [weak self] drop in
            guard let self else { return }
            switch drop {
            case .hidden:
                return
            case .backlog, .noDrawable, .notPresented:
                telemetry.recordDrop(at: CACurrentMediaTime())
            case .failed(let reason):
                telemetry.recordDrop(at: CACurrentMediaTime())
                if renderFailure != reason { renderFailure = reason }
            }
        }
    }

    public var resolutionLabel: String {
        guard pixelSize != .zero else { return "·" }
        let base = "\(Int(pixelSize.width))×\(Int(pixelSize.height)) @\(Int(scale))x"
        let f = fitFactor
        return f < 1 ? "\(base) · \(Int((f * 100).rounded()))%" : base
    }

    /// The content's point size at 1:1 on this view's screen.
    private var naturalPointSize: CGSize {
        sink.view?.pointSize(forPixelSize: pixelSize) ?? CGSize(width: pixelSize.width / scale, height: pixelSize.height / scale)
    }

    /// Room for the picture on the window's screen, leaving space for the title bar, the strip and a margin.
    private var pictureLimit: CGSize? {
        guard let screen = sink.view?.window?.screen ?? NSScreen.main else { return nil }
        return CGSize(width: screen.visibleFrame.width - 40, height: screen.visibleFrame.height - 120)
    }

    private var fitFactor: CGFloat {
        guard pixelSize != .zero, let limit = pictureLimit else { return 1 }
        return Fit.factor(natural: naturalPointSize, limit: limit)
    }

    /// 1:1 when it fits the screen, scaled down otherwise (VideoView then draws it with Lanczos), never up.
    public var fittedPointSize: CGSize {
        guard pixelSize != .zero else { return CGSize(width: 720, height: 450) }
        guard let limit = pictureLimit else { return naturalPointSize }
        return Fit.size(natural: naturalPointSize, limit: limit)
    }

    /// Shows the system picker. Ignored while picking or capturing; after a cancel or a failure it stops
    /// the old session first and starts a fresh one, so a second Share never leaves a session behind.
    public func start(excludingWindowIDs: [CGWindowID]) {
        if case .picking = state { return }
        if case .capturing = state { return }
        excludedWindowIDs = excludingWindowIDs
        failureNeedsPermission = false
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

    private func beginSession() {
        let session = makeSource()
        capture = session
        // The loops hold the model weakly: a session's streams never finish on their own, so a strong
        // reference here would keep every model alive for as long as the process runs.
        tasks = [
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
                    if let rtt = link?.lastRTTMs { telemetry.recordRTT(ms: rtt, at: CACurrentMediaTime()) }
                    if isSending, !loopback, let link, let encoder {
                        let bps = controller.update(rttMs: link.lastRTTMs, backlogBytes: link.backlogBytes, frameAgeMs: nil,
                                                    fps: max(snapshot.captureFPS, 30), now: CACurrentMediaTime())
                        if bps != currentBitrate { currentBitrate = bps; encoder.setBitrate(bps) }
                    }
                    // A source that went still after the drop sends no frame that could check the drain: this does.
                    if isSending, let link { keyframeAfterDrain(backlog: link.backlogBytes, now: CACurrentMediaTime()) }
                    snapshot = telemetry.snapshot(now: CACurrentMediaTime())
                    codecMs = loopback ? codecWindow.stats(now: CACurrentMediaTime())?.p50 : nil
                }
            },
        ]
        session.presentPicker(excludingWindowIDs: excludedWindowIDs)
    }

    /// Cancels the current session's loops and queues its stop behind every earlier one.
    private func retireSession() {
        tasks.forEach { $0.cancel() }
        tasks = []
        link?.close(); link = nil; advertiser?.stop(); advertiser = nil; linkTasks.forEach { $0.cancel() }; linkTasks = []; isSending = false; viewerName = nil
        unpaired.values.forEach { $0.link.close(); $0.states.cancel() }; unpaired = [:]
        listeningPort = nil; networkNotice = nil
        loopback = false
        qualityRestToken &+= 1
        // The view keeps the last frame for redraws; hand it back so the old stream's buffer pool can drain. The model
        // lets go of the same frame, and a new session never encodes the old one.
        sink.releaseHeldFrame()
        latestRaw = nil
        guard let old = capture else { return }
        capture = nil
        let earlier = Self.retiring
        Self.retiring = Task { @MainActor in
            await earlier?.value
            await old.stop()
        }
    }

    private func ingest(_ frame: CapturedFrame) {
        telemetry.recordCapture(at: Double(frame.captureHostTimeNs) / 1e9)
        lastCaptureAt = CACurrentMediaTime()
        latestRaw = frame
        // Encode for the loop or a viewer, and only while capturing: after a failure (the encoder's included) the raw
        // picture goes on until Retry, and no encoder is made again for every frame. The sharer sees the raw picture
        // unless the loop shows the decoded one.
        let encoding = (loopback || isSending) && state == .capturing
        if !(loopback && encoding) { sink.push(frame.pixelBuffer, captureHostTimeNs: frame.captureHostTimeNs) }
        guard encoding else { return }
        encode(frame.pixelBuffer, captureHostTimeNs: frame.captureHostTimeNs)
    }

    /// A still source sends no frame (`CaptureSession` forwards only changed ones), so the loop or a viewer would show
    /// nothing until the content changed: the newest raw frame is encoded again. It is stamped now, as it reaches the
    /// encoder, so the capture→display figure counts the codec and the display, not how long the source has been still
    /// (which could be seconds, and over five would be logged as the clocks disagreeing). It is not a new capture.
    private func encodeNewestAgain() {
        guard loopback || isSending, state == .capturing, let raw = latestRaw else { return }
        encode(raw.pixelBuffer, captureHostTimeNs: UInt64(CACurrentMediaTime() * 1e9))
    }

    /// Hands a frame to the encoder, made (again) for its size; `handleDecoded` shows the result against `latestRaw`.
    private func encode(_ pixelBuffer: CVPixelBuffer, captureHostTimeNs: UInt64) {
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        if encoder == nil || encoder?.width != width || encoder?.height != height { makeEncoder(width: width, height: height) }
        guard let encoder else { return }
        let n = encoder.nextSeq
        // The loop's codec time; only a decoded loop frame takes its start back, so a frame for the viewer alone has none.
        if loopback { encodeStarts[n] = CACurrentMediaTime() }
        if !encoder.encode(pixelBuffer, captureHostTimeNs: captureHostTimeNs) {
            encodeStarts.removeValue(forKey: n)
            // `nextSeq` moves only once the encoder has taken the frame. A refusal after that went to `onError`, which
            // counts it; a frame turned away at the two-in-flight cap, or by an invalidated encoder, is counted here.
            if encoder.nextSeq == n { telemetry.recordDrop(at: CACurrentMediaTime()) }
        }
    }

    private func makeEncoder(width: Int, height: Int) {
        encoder?.invalidate(); decoder?.invalidate(); decoder = nil; decoderConfig = nil
        codecNotice = nil; encodeFailures = 0; decodeFailures = 0
        do {
            let bitsPerSecond = loopback ? Int(qualityMbps * 1_000_000) : BitrateController.initialBitrate(width: width, height: height)
            let e = try VideoEncoder(width: width, height: height, preferred: .hevc, bitsPerSecond: bitsPerSecond)
            e.onFrame = { [weak self] f in Task { @MainActor in self?.handleEncoded(f) } }
            // Set before the first encode. It runs on a VideoToolbox queue, or on this thread inside `encode` and
            // `setBitrate`, and a setting rejected inside `init` arrives the moment it is set: so it hops to the main actor.
            // The encoder feeds the viewer too, so a frame it fails or drops freezes the viewer's picture as well, and
            // only this tells the sharer.
            e.onError = { [weak self] err in Task { @MainActor in self?.handleCodecError(err) } }
            encoder = e
            currentBitrate = bitsPerSecond; controller = BitrateController(initial: currentBitrate)
            codecLabel = e.codec == .hevc ? "HEVC" : "H.264"
        } catch {
            log.error("could not create the video encoder: \(String(describing: error), privacy: .public)")
            state = .failed("Hardware video encoder unavailable: \(error)")
        }
    }

    /// Internal, not private, so a test can hand it a frame the decoder cannot read.
    func handleEncoded(_ f: EncodedFrame) {
        let now = CACurrentMediaTime()
        encodeFailures = 0
        telemetry.recordBytes(f.data.count, at: now)
        if isSending, let link {
            // Spec section 8: skip non-key frames while the backlog exceeds four frames' worth, then send the next
            // keyframe. A delta after a drop refers to frames the viewer never got, so none goes out until it has.
            let backlog = link.backlogBytes
            if !f.isKey, needKeyAfterDrain || backlog > 4 * frameBytes {
                if !needKeyAfterDrain { log.info("send backlog of \(backlog, privacy: .public) bytes; skipping frames until a keyframe") }
                telemetry.recordDrop(at: now); needKeyAfterDrain = true
                keyframeAfterDrain(backlog: backlog, now: now)
            } else {
                if f.isKey { needKeyAfterDrain = false; drainKeyRequestedAt = nil }
                if let cfg = f.videoConfig { link.send(.videoConfig(cfg)) }
                link.send(.videoFrame(f.videoFrame))
            }
        }
        guard loopback else { return }
        if let cfg = f.videoConfig, cfg != decoderConfig {
            do {
                decoder = try VideoDecoder(config: cfg); decoderConfig = cfg
            } catch {
                log.error("could not create the video decoder: \(String(describing: error), privacy: .public)")
                state = .failed("Decoder: \(error)"); return
            }
            decoder?.onFrame = { [weak self] d in Task { @MainActor in self?.handleDecoded(d) } }
            decoder?.onError = { [weak self] err in Task { @MainActor in self?.handleCodecError(err, from: "decoder") } }
        }
        guard let decoder else { return }
        do {
            try decoder.decode(f.videoFrame)
            decodeFailures = 0
        } catch {
            // While the loop is on only decoded frames reach the screen, so a decoder that keeps throwing freezes the
            // picture: ten in a row fail the share with Retry, like the encoder (and the viewer's rule in Task 14).
            log.error("the video decoder could not decode frame \(f.seq, privacy: .public): \(String(describing: error), privacy: .public)")
            telemetry.recordDrop(at: now)
            encodeStarts.removeValue(forKey: f.seq)   // this frame never decodes
            decoder.invalidate(); self.decoder = nil; decoderConfig = nil
            decodeFailures += 1
            if decodeFailures >= 10 { failCodec("decoder", message: "Video decoding keeps failing."); return }
            encoder?.requestKeyframe()
        }
    }

    /// After a drop, once the backlog is under one frame's worth: asks for the keyframe that lets the viewer decode again.
    /// `sendKeyframe` covers a still source too (it encodes the newest frame again), so the viewer never keeps a damaged
    /// or stale picture until the content moves. Asks again only if no keyframe went out within a second. With no
    /// encoder there is nothing to ask: the next frame makes one, and a fresh encoder starts with a keyframe.
    private func keyframeAfterDrain(backlog: Int, now: CFTimeInterval) {
        guard needKeyAfterDrain, backlog < frameBytes, encoder != nil else { return }
        if let asked = drainKeyRequestedAt, now - asked < 1 { return }
        drainKeyRequestedAt = now
        log.info("the send backlog drained after dropped frames; sending a keyframe")
        sendKeyframe()
    }

    /// Codec failures that are not thrown (Task 9's `onError`); the codec has logged them. A frame the encoder failed,
    /// dropped or emitted empty counts in the strip's dropped figure, and ten in a row fail the share with Retry, like
    /// the viewer's ten-failure rule for decoding (Task 14). A rejected setting is said in a notice over the picture.
    private func handleCodecError(_ error: CodecError, from part: String = "encoder") {
        switch error {
        case .encode, .frameDropped, .missingData:
            let now = CACurrentMediaTime()
            telemetry.recordDrop(at: now)
            encodeStarts = encodeStarts.filter { now - $0.value < 1 }   // a failed frame never decodes; drop its start
            encodeFailures += 1
            if encodeFailures >= 10 { failCodec("encoder", message: "Video encoding keeps failing.") }
        case .property(let key, let status):
            codecNotice = "The video \(part) rejected its \(key) setting (\(status)); the picture goes on without it."
        case .sessionCreate, .decode, .formatDescription, .prepare:
            codecNotice = "Video \(part): \(error)"   // Task 9 throws these instead; shown all the same if one ever arrives
        }
    }

    /// The encoder or the decoder (`part`) is not coming back by itself: stop both, keep the raw picture, offer Retry
    /// (a fresh session and encoder).
    private func failCodec(_ part: String, message: String) {
        log.error("the video \(part, privacy: .public) failed 10 frames in a row")
        encoder?.invalidate(); decoder?.invalidate(); encoder = nil; decoder = nil; decoderConfig = nil
        encodeFailures = 0; decodeFailures = 0; codecLabel = "raw"; codecMs = nil; encodeStarts.removeAll()
        state = .failed(message)
    }

    private func handleDecoded(_ d: DecodedFrame) {
        // A frame decoded after the loop was turned off (or the share failed) would put the comparison back on
        // screen, and a still source would leave it there: the raw picture already took its place.
        guard loopback, state == .capturing else { return }
        if let start = encodeStarts.removeValue(forKey: d.seq) { codecWindow.add((CACurrentMediaTime() - start) * 1000, at: CACurrentMediaTime()) }
        if encodeStarts.count > 120 { encodeStarts.removeAll() }
        sink.push(d.pixelBuffer, captureHostTimeNs: d.captureHostTimeNs, compareWith: latestRaw?.pixelBuffer, dividerAt: dividerPosition)
    }

    private func loopbackDidChange() {
        guard !loopback else {
            // On at once: a still source sends no frame to start the loop with, so the one on screen is encoded now.
            encodeNewestAgain()
            return
        }
        qualityRestToken &+= 1
        encoder?.invalidate(); decoder?.invalidate(); encoder = nil; decoder = nil; decoderConfig = nil
        codecLabel = "raw"; codecMs = nil; encodeStarts.removeAll(); codecNotice = nil; encodeFailures = 0; decodeFailures = 0
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
    private func qualityDidChange() {
        guard let encoder else { return }
        encoder.setBitrate(Int(qualityMbps * 1_000_000))
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
    /// rest, not once per slider step.
    private func qualityRested() {
        guard loopback, state == .capturing, encoder != nil, let raw = latestRaw,
              CACurrentMediaTime() - lastCaptureAt >= Self.stillAfter else { return }
        makeEncoder(width: CVPixelBufferGetWidth(raw.pixelBuffer), height: CVPixelBufferGetHeight(raw.pixelBuffer))
        encodeNewestAgain()
    }

    private func handle(_ event: CaptureEvent) {
        switch event {
        case .started(let w, let h, let s):
            pixelSize = CGSize(width: w, height: h); scale = s; state = .capturing
            startAdvertising()
        case .cancelled:
            state = .idle
        case .stopped:
            state = .idle
        case .failed(let message):
            // Before the first frame, a missing Screen Recording grant is the likely cause.
            failureNeedsPermission = state != .capturing && !screenRecordingGranted()
            state = .failed(message)
        }
    }

    // MARK: Viewers

    private func startAdvertising() {
        guard advertiser == nil else { return }
        do {
            let adv = try Advertiser(name: name, code: code, hello: hello)
            advertiser = adv
            // Weak on every connection, as in every ShareModel loop: a whole-loop `guard let self` keeps the model
            // alive for as long as the listener lives (Task 8 fix round 1).
            tasks.append(Task { [weak self] in
                // Retired before it ran: the listener is stopped already, and starting it now would wait forever.
                guard !Task.isCancelled else { return }
                do {
                    let port = try await adv.start()
                    log.info("listening for viewers on port \(port, privacy: .public)")
                    self?.listeningPort = port
                } catch {
                    // A failure is also on `adv.states`, which fails the share (`advertiserStateChanged`). A listener
                    // stopped before it was ready throws too, and that is a retired session, not a failure.
                    return
                }
                for await incoming in adv.incoming {
                    guard let self else { return }
                    attach(incoming)
                }
            })
            // A listener that fails after it started ends `incoming` without a word: its states say why.
            tasks.append(Task { [weak self] in
                for await s in adv.states {
                    guard let self else { return }
                    advertiserStateChanged(s, of: adv)
                }
            })
        } catch {
            log.error("could not create the network listener: \(String(describing: error), privacy: .public)")
            state = .failed("Could not start the network listener: \(error.localizedDescription)")
        }
    }

    /// A wait says why viewers cannot reach this Mac yet (Local Network off, for one). A failure, before or after the
    /// listener was ready, fails the share with Retry: nobody could join it any more. A retired listener says nothing.
    private func advertiserStateChanged(_ s: Advertiser.State, of adv: Advertiser) {
        guard adv === advertiser else { return }
        switch s {
        case .ready: networkNotice = nil
        case .waiting(let reason): networkNotice = "Viewers cannot reach this Mac: \(reason)"
        case .failed(let reason):
            networkNotice = nil
            state = .failed("Could not listen on the local network: \(reason)")
        case .stopped: break
        }
    }

    /// One viewer at a time, and only one that proved the code. The listener hands a connection over before its
    /// TLS-PSK handshake has run, so it could be anybody on the network: a port scan, or a viewer with a mistyped
    /// code. It waits here, apart from the viewer, and takes over only once it is ready (`linkStateChanged`).
    private func attach(_ incoming: NitidoLink.Link) {
        // Weak on every state, as every ShareModel loop is (Task 8 fix round 1). Plain tasks rather than a task group:
        // Swift 6 rejects a weak capture of the model in a group's `@MainActor` child task.
        let states = Task { [weak self] in
            for await s in incoming.states {
                guard let self else { return }
                linkStateChanged(s, for: incoming)
            }
        }
        unpaired[ObjectIdentifier(incoming)] = (incoming, states)
    }

    private func linkStateChanged(_ s: NitidoLink.Link.State, for l: NitidoLink.Link) {
        switch s {
        case .ready:
            // The handshake proved the code: this viewer takes over from the current one, which is told the sharer
            // ended its session. Its messages are heard from now on (they wait in the link's stream until then).
            guard let pairing = unpaired.removeValue(forKey: ObjectIdentifier(l)) else { return }
            link?.close()
            linkTasks.forEach { $0.cancel() }
            link = l; viewerName = l.peerHello?.name; isSending = true
            linkTasks = [
                pairing.states,
                Task { [weak self] in
                    for await m in l.messages {
                        guard let self, link === l else { return }
                        handleIncoming(m)
                    }
                },
            ]
            sendKeyframe()
        case .failed(let m):
            if unpaired.removeValue(forKey: ObjectIdentifier(l)) != nil {
                // A wrong code, or not a viewer at all: the viewer, if any, goes on as it was. A link that was the
                // viewer's had proved the code, so only these count as failed handshakes.
                log.info("a connection ended before it proved the code: \(m)")
                failedHandshakes += 1; if failedHandshakes >= 3 { rotateCode() }
                return
            }
            guard l === link else { return }
            isSending = false; viewerName = nil; link = nil; log.info("viewer link failed: \(m)")
        case .cancelled:
            if unpaired.removeValue(forKey: ObjectIdentifier(l)) != nil { return }
            guard l === link else { return }
            isSending = false; viewerName = nil; link = nil
        case .connecting: break
        }
    }

    /// Three failed handshakes in a row mean someone is guessing: new code, new key.
    private func rotateCode() {
        failedHandshakes = 0
        // A new code, never the one being guessed (`makeCode` repeats one in 10,000 draws).
        let old = code
        repeat { code = Pairing.makeCode() } while code == old
        log.info("three connections failed to prove the code; showing a new one")
        advertiser?.stop(); advertiser = nil
        listeningPort = nil   // the stopped listener's port; the new listener sets its own once ready
        startAdvertising()
    }

    private func handleIncoming(_ m: Message) {
        switch m {
        case .hello(let h): viewerName = h.name
        case .stroke(let s): ink.applyRemote(s)
        case .undo(let id): ink.undoRemote(id: id)
        case .clear: ink.clearRemote()
        case .cursor(let c): ink.remoteCursor(c, name: viewerName ?? "Viewer")
        case .keyframeRequest: sendKeyframe()
        default: break
        }
    }

    /// The next frame the viewer gets is a keyframe. A still source sends no next frame (`CaptureSession` forwards only
    /// changed ones), so a viewer that just connected, or lost its decoder, would see nothing until the content moved:
    /// when no frame comes within `stillAfter`, the newest one is encoded again (a fresh encoder's first frame is a
    /// keyframe, a running one's is after the request).
    private func sendKeyframe() {
        encoder?.requestKeyframe()
        let requestedAt = CACurrentMediaTime()
        Task { [weak self] in
            do { try await Task.sleep(for: .seconds(Self.stillAfter)) } catch { return }
            guard let self, lastCaptureAt < requestedAt else { return }   // a newer frame carried the keyframe
            encodeNewestAgain()
        }
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
}
