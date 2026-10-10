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
    /// Frames the source let go before the share took them, since the last call (`CaptureSession.takeDroppedFrames`).
    func takeDroppedFrames() -> Int
}

extension CaptureSource {
    func takeDroppedFrames() -> Int { 0 }
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
    /// Rotates after three wrong codes (`rotateCode`, `HandshakeFailures`).
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
    /// Internal, not private, so a test can stand in for VideoToolbox's callbacks on the encoder the share made.
    private(set) var encoder: VideoEncoder?
    /// Internal, not private, so a test can hold the loop's decoder queue, as a stall would.
    private(set) var decoder: VideoDecoder?
    private var decoderConfig: VideoConfig?
    /// The newest captured frame, raw: the left of the comparison while the loop is on. While it is off it is the frame
    /// the view holds (it was pushed raw), so it pins no buffer of its own; turning the loop on encodes it at once,
    /// since a still source sends no frame to start with (`encodeNewestAgain`). Cleared with the session.
    private var latestRaw: CapturedFrame?
    /// When the newest frame came (`CACurrentMediaTime`): a still source sends none.
    @ObservationIgnored private var lastCaptureAt: CFTimeInterval = 0
    /// When the encoder last took a frame (`CACurrentMediaTime`): a frame it turned away carries no keyframe.
    @ObservationIgnored private var lastAcceptedAt: CFTimeInterval = 0
    /// The newest frame was turned away at the encoder's two-in-flight cap, and nothing newer has been taken since: the
    /// next encoder output or frame failure, either of which frees a slot, encodes it (`encodePendingNewest`). Spec
    /// sections 5 and 8: the newest frame is the one that gets through, and a still source would send no other.
    @ObservationIgnored private var newestPending = false
    /// Bumped by every quality change, loop off and retire, so a pending `qualityRested` for an earlier one does nothing.
    @ObservationIgnored private var qualityRestToken: UInt64 = 0
    private var encodeStarts: [UInt32: Double] = [:]
    private var codecWindow = RollingWindow(seconds: 1)
    /// A codec setting VideoToolbox rejected (`CodecError.property` through `onError`), shown over the picture.
    public private(set) var codecNotice: String?
    /// Frames the encoder failed or emitted empty in a row; ten fail the share (`handleCodecError`). A frame
    /// VideoToolbox dropped is a dropped frame, and neither counts here nor starts the count again.
    private var encodeFailures = 0
    /// Every frame counted as dropped since the model was made. Internal for tests.
    var droppedFramesTotal: Int { telemetry.droppedTotal }
    /// Frames the loop's decoder could not read in a row; ten fail the share (`loopDecodeFailed`). Only a frame decoded
    /// resets it. Internal, not private, so a test can wait for a failure to land.
    private(set) var decodeFailures = 0
    /// When the loop last asked the encoder for a keyframe because its decoder skipped frames (`handleEncoded`).
    @ObservationIgnored private var loopKeyframeAskedAt: CFTimeInterval?
    /// The share failed because its capture ended (`CaptureEvent.failed`: Stop Sharing in the menu bar, a stream that
    /// stopped, or one that could not start or change). The session's picker is still up, and a new pick from it
    /// (`.started`) resumes the share without Retry. A codec or listener failure does not set it: the stream it leaves
    /// running may report a new size, and that must not clear the failure (`handle`). Cleared once capturing again.
    @ObservationIgnored private var captureFailed = false

    public private(set) var viewerName: String?
    public private(set) var isSending = false
    /// The viewer's link ended without `bye` (a cut network, a viewer that died): its name stays in the pairing panel as
    /// reconnecting until it pairs again, another viewer pairs, or `reconnectGrace` passes (spec 12, "Link drops").
    public private(set) var viewerReconnecting = false
    /// How long a dropped viewer is shown as reconnecting. Internal so a test can shorten it.
    @ObservationIgnored var reconnectGrace: Duration = .seconds(30)
    /// Bumped whenever the viewer changes, so a pending grace period for an earlier drop does nothing.
    @ObservationIgnored private var reconnectGraceToken: UInt64 = 0
    /// Viewers that proved the code so far: each one draws the gold ring once (`ConnectRing`).
    public private(set) var connectionCount = 0
    /// The connection the gold ring last played for, so the Share screen shown again draws it at rest (`ConnectRing`).
    @ObservationIgnored public var ringShownFor = 0
    /// The first pick's picker was cancelled: the app goes back to Welcome (`AppModel.startShare`).
    public var onCancelled: (() -> Void)?
    /// Why viewers cannot reach this Mac right now (the listener is waiting), shown over the picture.
    public private(set) var networkNotice: String?
    /// A Mac on another protocol version proved the code and could not pair (spec 12), shown over the picture until a
    /// viewer pairs or the share stops.
    public private(set) var viewerNotice: String?
    /// The name Bonjour registered the share under, which viewers see in their list: `name`, or "Name (2)" when another
    /// Mac on the network has that name. Nil while nothing is advertised.
    public private(set) var advertisedName: String?
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
    /// Adapts the viewer's bitrate every 250 ms (the snapshot loop), from the RTT, the send backlog and the skips the
    /// dropping rule started (`backlogPolicy`).
    private var controller = BitrateController(initial: 20_000_000)
    /// The encoder's rate, which also sizes the backlog dropping rule (`backlogPolicy`).
    private var currentBitrate = 20_000_000
    /// One frame's worth of bytes at the current rate: the unit the backlog drains to. Internal for tests.
    var frameBytes: Int { BacklogPolicy.frameBytes(bitsPerSecond: currentBitrate) }
    /// Spec section 8's dropping rule for the viewer's link: when deltas are skipped for the send backlog, and when the
    /// keyframe that ends the skip is asked for (`handleEncoded`, `keyframeAfterDrain`). Each viewer starts it afresh.
    @ObservationIgnored private var backlogPolicy = BacklogPolicy()
    /// A viewer just took over (`linkStateChanged`): it has none of the frames the deltas still in the encoder refer to,
    /// so none goes out to it before the keyframe the takeover asked for (`handleEncoded`).
    @ObservationIgnored private var viewerNeedsKeyframe = false
    /// The keyframes forced for the viewer, its own asks and the sharer's (a takeover, the drain after a skip): at most
    /// one per half second (`KeyframeLimiter`, `forceKeyframe`). A new viewer starts it afresh, so its first keyframe
    /// goes at once; a viewer that comes back (the same address) keeps it.
    @ObservationIgnored private var forcedKeyframes = KeyframeLimiter()
    /// The address the viewer `forcedKeyframes` counts for came from (`Link.remoteHost`).
    @ObservationIgnored private var forcedKeyframesViewer: String?
    /// Bumped whenever `forcedKeyframes` starts afresh, so a keyframe due for an earlier viewer is not forced.
    @ObservationIgnored private var forcedKeyframesToken: UInt64 = 0
    /// When a keyframe last went out to the viewer (`CACurrentMediaTime`): a forced one due after it is not needed.
    @ObservationIgnored private var keyframeSentAt: CFTimeInterval?
    /// Wrong codes over the whole share, counted per attempt; three rotate it (`rotateCode`).
    private var handshakeFailures = HandshakeFailures()
    /// Wrong codes since the code last changed. Internal for tests.
    var wrongCodeAttempts: Int { handshakeFailures.count }
    /// The clock wrong codes are counted by (`HandshakeFailures`). Internal so a test can move it on.
    @ObservationIgnored var handshakeClock: () -> CFTimeInterval = { CACurrentMediaTime() }
    /// The clock the backlog dropping rule reads (`BacklogPolicy`). Internal so a test can move it on.
    @ObservationIgnored var backlogClock: () -> CFTimeInterval = { CACurrentMediaTime() }

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
            case .backlog, .noDrawable, .notPresented, .replaced:
                telemetry.recordDrop(at: CACurrentMediaTime())
            case .failed(let reason):
                telemetry.recordDrop(at: CACurrentMediaTime())
                if renderFailure != reason { renderFailure = reason }
            }
        }
    }

    public var resolutionLabel: String { Fit.resolutionLabel(pixelSize: pixelSize, scale: scale, factor: fitFactor) }

    /// The content's point size at 1:1 on the display the picture is on. The sink says which (SwiftUI observes it, so
    /// the window takes the new size when it moves to a display of another scale); the main display until the view is
    /// in a window.
    private var naturalPointSize: CGSize {
        let s = sink.backingScale ?? NSScreen.main?.backingScaleFactor ?? scale
        return CGSize(width: pixelSize.width / s, height: pixelSize.height / s)
    }

    /// Room for the picture on that display's screen, leaving space for the title bar, the strip and a margin.
    private var pictureLimit: CGSize? {
        guard let frame = sink.visibleFrame ?? NSScreen.main?.visibleFrame else { return nil }
        return Fit.limit(visibleFrame: frame)
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
                    let now = CACurrentMediaTime()
                    if let rtt = link?.lastRTTMs { telemetry.recordRTT(ms: rtt, at: now) }
                    // Frames the capture stream let go because the share had not taken the one before yet.
                    for _ in 0..<(capture?.takeDroppedFrames() ?? 0) { telemetry.recordDrop(at: now) }
                    snapshot = telemetry.snapshot(now: now)
                    if isSending, let link {
                        // The measure the dropping rule judges, for it and the controller alike: without the keyframe
                        // on its way, one burst made on purpose and never congestion by itself; those behind it count.
                        let backlog = link.backlogBytesExcludingKeyframes
                        backlogPolicy.observe(backlogBytes: backlog, bitsPerSecond: currentBitrate, now: backlogClock())
                        let skipped = backlogPolicy.takeTrip()
                        if !loopback, let encoder {
                            // Spec 8: the RTT p50 of the last second, the strip's own figure, not the latest ping alone.
                            // A skip the dropping rule started since the last update cuts now, hold or not.
                            let bps = controller.update(rttMs: snapshot.rttMs, backlogBytes: backlog, frameAgeMs: nil,
                                                        fps: max(snapshot.captureFPS, 30), now: now, skippedForBacklog: skipped)
                            if bps != currentBitrate {
                                // For half a second after a cut, the dropping rule judges the backlog at the rate
                                // before it, so the cut does not trip a skip, and a second cut, by itself.
                                if bps < currentBitrate {
                                    backlogPolicy.rateCut(from: currentBitrate, now: backlogClock())
                                }
                                let rtt = snapshot.rttMs.map { String(format: "%.1f ms", $0) } ?? "unknown"
                                log.info("the bitrate goes from \(Double(self.currentBitrate) / 1e6, format: .fixed(precision: 1), privacy: .public) to \(Double(bps) / 1e6, format: .fixed(precision: 1), privacy: .public) Mbps: send backlog \(backlog, privacy: .public) bytes, RTT p50 \(rtt, privacy: .public)\(skipped ? ", frames skipped for the backlog" : "", privacy: .public)")
                                currentBitrate = bps; encoder.setBitrate(bps)
                            }
                        }
                        // A source that went still after the drop sends no frame that could check the drain: this does.
                        keyframeAfterDrain(backlog: backlog, now: backlogClock())
                    }
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
        // The viewer is told `bye` now; a stop returns only once it is out (`stop` waits for `retiring`), so a quit
        // does not cut it off.
        let byeSent = link.map { viewer in Task { await viewer.closeAndWait() } }
        link = nil; advertiser?.stop(); advertiser = nil; linkTasks.forEach { $0.cancel() }; linkTasks = []; isSending = false; viewerName = nil
        viewerReconnecting = false; reconnectGraceToken &+= 1; viewerNeedsKeyframe = false
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
    /// encoder, so the capture-to-display figure counts the codec and the display, not how long the source has been still
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
        if encoder.encode(pixelBuffer, captureHostTimeNs: captureHostTimeNs) {
            newestPending = false; lastAcceptedAt = CACurrentMediaTime()
        } else {
            encodeStarts.removeValue(forKey: n)
            // `nextSeq` moves only once the encoder has taken the frame. A refusal after that went to `onError`, which
            // counts it; a frame turned away at the two-in-flight cap is counted here, and is encoded again as soon as a
            // slot frees, unless a newer frame gets in first. The model never holds an invalidated encoder (`dropCodec`
            // goes with every invalidation), so a refusal here is always the cap.
            if encoder.nextSeq == n { telemetry.recordDrop(at: CACurrentMediaTime()); newestPending = true }
        }
    }

    /// After an encoder output or a frame failure, which frees a slot: the newest frame, turned away at the cap, goes in
    /// now with its own capture time. Turned away again, it stays pending for the next one, so nothing builds a queue.
    private func encodePendingNewest() {
        guard newestPending else { return }
        newestPending = false
        guard loopback || isSending, state == .capturing, let raw = latestRaw else { return }
        encode(raw.pixelBuffer, captureHostTimeNs: raw.captureHostTimeNs)
    }

    private func makeEncoder(width: Int, height: Int) {
        encoder?.invalidate(); decoder?.invalidate(); decoder = nil; decoderConfig = nil
        codecNotice = nil; encodeFailures = 0; decodeFailures = 0
        do throws(CodecError) {
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
            // The encoder invalidated above goes with the failure: kept, Retry at its size would reuse it, and an
            // invalidated encoder turns every frame away (`encode` would count each as a drop and wait for a slot
            // that never frees).
            dropCodec()
            state = .failed("This Mac's hardware video encoder could not start\(error.statusNote); press Retry to try again.")
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
        if isSending, let link {
            // Spec section 8: skip non-key frames once the backlog has stayed over 150 ms worth for 100 ms, or is over a
            // second's worth, then send the next keyframe (`BacklogPolicy`). A delta after a drop refers to frames the
            // viewer never got, so none goes out until it has. The keyframe on its way is left out of the backlog.
            let backlog = link.backlogBytesExcludingKeyframes
            let at = backlogClock()
            if !f.isKey, viewerNeedsKeyframe {
                // A delta encoded before the viewer took over: it never had the frames it refers to. Not a dropped frame,
                // since this viewer was never going to see it; its keyframe is on the way (`sendKeyframe`).
            } else if f.isKey {
                // A keyframe always goes out: it ends a skip (and starts the rule's hold-off) or a takeover's wait.
                backlogPolicy.keyframeSent(now: at)
                viewerNeedsKeyframe = false
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
        guard loopback else { return }
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
            if !f.isKey { encoder?.requestKeyframe() }
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
            encoder?.requestKeyframe()
        } else if loopKeyframeAskedAt.map({ now - $0 >= 1 }) ?? true {
            loopKeyframeAskedAt = now
            encoder?.requestKeyframe()
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
        encoder?.requestKeyframe()
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
    /// picture until the content moves. Asks again only if no keyframe went out within a second. With no encoder there
    /// is nothing to ask: the next frame makes one, and a fresh encoder starts with a keyframe. The log line says
    /// whether the keyframe goes now or when the limit lets it, as a tester reads it (docs/testing.md item 19): one held
    /// for up to half a second, logged as sent, looked like the skips the item checks for.
    private func keyframeAfterDrain(backlog: Int, now: CFTimeInterval) {
        guard encoder != nil, backlogPolicy.keyframeDue(backlogBytes: backlog, bitsPerSecond: currentBitrate, now: now) else { return }
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

    /// Codec failures that are not thrown (Task 9's `onError`); the codec has logged them. A frame the encoder failed
    /// or emitted empty counts in the strip's dropped figure, and ten in a row fail the share with Retry, like the
    /// viewer's ten-failure rule for decoding (Task 14). A frame VideoToolbox dropped is only a dropped frame
    /// (`droppedByEncoder`). A rejected setting is said in a notice over the picture.
    private func handleCodecError(_ error: CodecError, from part: String = "encoder") {
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
            // away, goes in now; a still source would send no other. Not once the encoder is gone (the loop turned off,
            // a share retired): a late failure from it makes no new one.
            if encoder != nil { encodePendingNewest() }
        case .property(let key, let status):
            codecNotice = "The video \(part) rejected its \(CodecError.settingName(key)) setting (error \(status)); the picture goes on without it."
        case .sessionCreate, .decode, .formatDescription, .prepare:
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

    /// The encoder or the decoder (`part`) is not coming back by itself: stop both, keep the raw picture, offer Retry
    /// (a fresh session and encoder).
    private func failCodec(_ part: String, message: String) {
        log.error("the video \(part, privacy: .public) failed 10 frames in a row")
        dropCodec()
        state = .failed(message)
        endViewers()
    }

    /// Lets the encoder and the decoder go, with their counts and figures: the next frame to encode makes a fresh
    /// encoder (`encode`), which starts with a keyframe.
    private func dropCodec() {
        encoder?.invalidate(); decoder?.invalidate(); encoder = nil; decoder = nil; decoderConfig = nil
        encodeFailures = 0; decodeFailures = 0; codecLabel = "raw"; codecMs = nil; encodeStarts.removeAll(); newestPending = false
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
        sink.push(d.pixelBuffer, captureHostTimeNs: d.captureHostTimeNs, compareWith: latestRaw?.pixelBuffer, dividerAt: dividerPosition)
    }

    private func loopbackDidChange() {
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
    private func qualityRested() {
        guard loopback, state == .capturing, encoder != nil, let raw = latestRaw,
              CACurrentMediaTime() - lastCaptureAt >= Self.stillAfter else { return }
        makeEncoder(width: CVPixelBufferGetWidth(raw.pixelBuffer), height: CVPixelBufferGetHeight(raw.pixelBuffer))
        encodeNewestAgain()
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
                failureNeedsPermission = false; codecNotice = nil
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
                    // Ready just before a rotation or a failure retired it, this listener's port is no longer the one
                    // viewers can reach.
                    if let self, adv === advertiser {
                        log.info("listening for viewers on port \(port, privacy: .public)")
                        listeningPort = port
                    }
                } catch {
                    // A failure is also on `adv.states`, which fails the share (`advertiserStateChanged`). A listener
                    // stopped before it was ready throws too, and that is a retired session, not a failure.
                    return
                }
                for await incoming in adv.incoming {
                    guard let self else { return }
                    // A connection the listener took before a rotation or a failure retired it (`rotateCode`,
                    // `endViewers`) can still be in its stream: it was made for a code or a share that is gone, so it
                    // goes, rather than pair with the old code or count against the new one.
                    guard adv === advertiser else { incoming.close(); continue }
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
            state = .failed("Nítido could not listen for viewers on the local network (error \((error as NSError).code)). Press Retry to try again.")
            endViewers()
        }
    }

    /// A wait says why viewers cannot reach this Mac yet (Local Network off, for one). A failure, before or after the
    /// listener was ready, fails the share with Retry: nobody could join it any more. A retired listener says nothing.
    private func advertiserStateChanged(_ s: Advertiser.State, of adv: Advertiser) {
        guard adv === advertiser else { return }
        switch s {
        case .ready: networkNotice = nil
        case .advertised(let registered): advertisedName = registered
        case .waiting(let reason): networkNotice = "Viewers cannot reach this Mac. \(reason)"
        case .failed(let reason):
            networkNotice = nil
            state = .failed("Nítido stopped listening for viewers on the local network. \(reason) Press Retry to listen again.")
            endViewers()
        case .stopped: break
        }
    }

    /// The share stopped sending: a capture, codec or listener failure, or Stop Sharing in the menu bar (the stream ends
    /// with an error). The viewer is told with `bye(sharingStopped)` and says the sharer stopped sharing, instead of
    /// staying connected over a frozen picture, and the listener stops, so nobody new pairs with a share that sends
    /// nothing. Retry listens again (`start`, then `.started`, then `startAdvertising`).
    private func endViewers() {
        if link != nil { log.info("the share stopped sending; ending the viewer's link and the listener") }
        link?.close(reason: ByeReason.sharingStopped); link = nil
        linkTasks.forEach { $0.cancel() }; linkTasks = []
        unpaired.values.forEach { $0.link.close(); $0.states.cancel() }; unpaired = [:]
        isSending = false; viewerName = nil; viewerReconnecting = false; reconnectGraceToken &+= 1; viewerNeedsKeyframe = false
        forgetForcedKeyframes()
        advertiser?.stop(); advertiser = nil; listeningPort = nil; networkNotice = nil; advertisedName = nil; viewerNotice = nil
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
            link = l; viewerName = l.peerHello?.name; isSending = true; connectionCount += 1
            viewerReconnecting = false; reconnectGraceToken &+= 1; viewerNotice = nil
            linkTasks = [
                pairing.states,
                Task { [weak self] in
                    for await m in l.messages {
                        guard let self, link === l else { return }
                        handleIncoming(m)
                    }
                },
            ]
            // Each viewer starts from the initial rate for the picture's size (spec 8), not from the rate a congested
            // viewer before it left. With the codec loop on, the slider keeps the rate; without an encoder, the next
            // frame makes one at the initial rate (`makeEncoder`).
            if !loopback, let encoder {
                currentBitrate = BitrateController.initialBitrate(width: encoder.width, height: encoder.height)
                controller = BitrateController(initial: currentBitrate)
                encoder.setBitrate(currentBitrate)
            }
            // A skip, a hold-off or a time over the threshold was the last viewer's link's.
            backlogPolicy = BacklogPolicy()
            viewerNeedsKeyframe = true
            // A new viewer's first keyframe goes at once; one that comes back shares the limit of its link before.
            let host = l.remoteHost
            if host == nil || host != forcedKeyframesViewer { forgetForcedKeyframes(); forcedKeyframesViewer = host }
            forceKeyframe()
        case .failed(let m):
            if unpaired.removeValue(forKey: ObjectIdentifier(l)) != nil {
                // It proved the code and speaks another protocol version: said over the picture (spec 12), and the
                // viewer, if any, goes on as it was. Not a wrong code.
                if l.incompatible { noteIncompatible(l); return }
                // A wrong code, or not a viewer at all: the viewer, if any, goes on as it was. A link that was the
                // viewer's had proved the code, so only these can count as wrong codes, and only those that failed on
                // the keys, once per attempt (`HandshakeFailures`).
                let host = l.remoteHost
                let counted = handshakeFailures.record(host: host, keyMismatch: l.keyMismatch, at: handshakeClock())
                let verdict = !l.keyMismatch ? "not a wrong code"
                    : counted ? "wrong code \(handshakeFailures.count) of \(HandshakeFailures.rotateAfter)"
                    : "the same attempt as the last failure from there"
                log.info("a connection from \(host ?? "an unknown address", privacy: .public) ended before it proved the code (\(verdict, privacy: .public)): \(m, privacy: .public)")
                if handshakeFailures.shouldRotate { rotateCode() }
                return
            }
            guard l === link else { return }
            // Gone without `bye`: a viewer reconnects by itself (`LinkSession`), so it is shown as reconnecting.
            isSending = false; link = nil; log.info("viewer link failed: \(m, privacy: .public)")
            viewerReconnecting = true
            reconnectGraceToken &+= 1
            let token = reconnectGraceToken, grace = reconnectGrace
            Task { [weak self] in
                do { try await Task.sleep(for: grace) } catch { return }
                guard let self, token == reconnectGraceToken, viewerReconnecting else { return }
                log.info("the viewer did not come back; waiting for a viewer")
                viewerReconnecting = false; viewerName = nil
            }
        case .cancelled:
            if unpaired.removeValue(forKey: ObjectIdentifier(l)) != nil {
                if l.incompatible { noteIncompatible(l) }
                return
            }
            guard l === link else { return }
            isSending = false; viewerName = nil; link = nil; viewerReconnecting = false; reconnectGraceToken &+= 1
        case .connecting: break
        }
    }

    /// A Mac that proved the code but speaks another protocol version (`Link.incompatible`): the share says so over the
    /// picture, naming both versions, and the Mac never took the seat (a link is ready only once the hellos match).
    private func noteIncompatible(_ l: NitidoLink.Link) {
        let who = l.peerHello?.name ?? "A Mac"
        let theirs = l.peerHello.map { " (protocol \($0.protocolVersion); this Mac speaks \(protocolVersion))" } ?? ""
        log.info("\(who, privacy: .public) proved the code but speaks another protocol version\(theirs, privacy: .public)")
        viewerNotice = "\(who) runs a different version of Nítido\(theirs). Update both Macs."
    }

    /// Three wrong codes over the share (a viewer pairing in between does not reset the count, spec 13) mean someone may
    /// be guessing: new code, new key, so a paired viewer can see the code change and need the new one after its next
    /// drop. Port probes and handshakes cut short do not count (`HandshakeFailures`). Internal so a test can change the
    /// code between a connection reaching the old listener's stream and the share taking it from there.
    func rotateCode() {
        handshakeFailures.rotated()
        // A new code, never the one being guessed (`makeCode` repeats one in 10,000 draws).
        let old = code
        repeat { code = Pairing.makeCode() } while code == old
        log.info("three wrong codes; showing a new one")
        // The connections still in their handshake on the old listener were made for the old code, which no longer
        // pairs: they go with it, so none can pair with the old code, nor fail later and count against the new one.
        if !unpaired.isEmpty {
            let n = unpaired.count
            log.info("letting go of \(n, privacy: .public) connection\(n == 1 ? "" : "s", privacy: .public) still proving the old code")
        }
        unpaired.values.forEach { $0.link.close(); $0.states.cancel() }; unpaired = [:]
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
        case .keyframeRequest: forceKeyframe()
        default: break
        }
    }

    /// A keyframe for the viewer, at most one per half second (`KeyframeLimiter`): at once, or when the half second
    /// since the last one forced is up, unless a keyframe has gone out by then. The viewer's asks (`keyframeRequest`)
    /// and the sharer's own (a takeover, the drain after a skip) all come here. A storm of them (the evening two-Mac
    /// test of 2026-10-09) filled the link the drain was meant to clear and made VideoToolbox drop frames. Returns the
    /// limiter's answer, which the drain's log line says.
    @discardableResult
    private func forceKeyframe() -> KeyframeLimiter.Answer {
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
    private func forgetForcedKeyframes() {
        forcedKeyframes = KeyframeLimiter(); forcedKeyframesViewer = nil
        forcedKeyframesToken &+= 1; keyframeSentAt = nil
    }

    /// The next frame the viewer gets is a keyframe. A still source sends no next frame (`CaptureSession` forwards only
    /// changed ones), so a viewer that just connected, or lost its decoder, would see nothing until the content moved:
    /// when the encoder takes no frame within `stillAfter` (a frame it turned away at its cap does not count), the
    /// newest one is encoded again (a fresh encoder's first frame is a keyframe, a running one's is after the request).
    /// Forced keyframes come through `forceKeyframe`, which keeps them half a second apart.
    private func sendKeyframe() {
        encoder?.requestKeyframe()
        let requestedAt = CACurrentMediaTime()
        Task { [weak self] in
            do { try await Task.sleep(for: .seconds(Self.stillAfter)) } catch { return }
            // A frame the encoder took since the request carried the keyframe; one it turned away at the cap did not.
            guard let self, lastAcceptedAt < requestedAt else { return }
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
