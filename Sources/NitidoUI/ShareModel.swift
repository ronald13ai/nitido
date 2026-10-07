import SwiftUI
import AppKit
import QuartzCore
import NitidoCore
import NitidoCapture
import NitidoCodec
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
    public let code = Pairing.makeCode()
    public let name = Host.current().localizedName ?? "Mac"
    /// True when the current failure most likely comes from a missing Screen Recording grant, so System Settings is the fix.
    public private(set) var failureNeedsPermission = false
    /// The last reason a frame could not be rendered; cleared by the next frame that reaches the screen.
    public private(set) var renderFailure: String?
    /// True when Screen Recording was not granted as the picker opened, so the picker screen explains the
    /// system prompt that may follow the pick before macOS shows it.
    public private(set) var mayAskForScreenRecording = false

    public var loopback = false { didSet { if loopback != oldValue { loopbackDidChange() } } }
    public var qualityMbps: Double = 20 { didSet { encoder?.setBitrate(Int(qualityMbps * 1_000_000)) } }
    public var dividerPosition: Double = 0.5
    public private(set) var codecMs: Double?
    public private(set) var codecLabel = "raw"
    private var encoder: VideoEncoder?
    private var decoder: VideoDecoder?
    private var decoderConfig: VideoConfig?
    private var latestRaw: CapturedFrame?
    private var encodeStarts: [UInt32: Double] = [:]
    private var codecWindow = RollingWindow(seconds: 1)
    /// A codec setting VideoToolbox rejected (`CodecError.property` through `onError`), shown over the picture.
    public private(set) var codecNotice: String?
    /// Frames the encoder failed, dropped or emitted empty in a row; ten fail the share (`handleCodecError`).
    private var encodeFailures = 0

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
        loopback = false
        // The view keeps the last frame for redraws; hand it back so the old stream's buffer pool can drain.
        sink.releaseHeldFrame()
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
        // Encode only while capturing: after a failure (the encoder's included) the raw picture goes on until Retry,
        // and no encoder is made again for every frame.
        guard loopback, state == .capturing else { sink.push(frame.pixelBuffer, captureHostTimeNs: frame.captureHostTimeNs); return }
        latestRaw = frame
        if encoder == nil || encoder?.width != frame.pixelWidth || encoder?.height != frame.pixelHeight { makeEncoder(for: frame) }
        guard let encoder else { return }
        let n = encoder.nextSeq
        encodeStarts[n] = CACurrentMediaTime()
        if !encoder.encode(frame.pixelBuffer, captureHostTimeNs: frame.captureHostTimeNs) {
            encodeStarts.removeValue(forKey: n)
            // `nextSeq` moves only once the encoder has taken the frame. A refusal after that went to `onError`, which
            // counts it; a frame turned away at the two-in-flight cap, or by an invalidated encoder, is counted here.
            if encoder.nextSeq == n { telemetry.recordDrop(at: CACurrentMediaTime()) }
        }
    }

    private func makeEncoder(for frame: CapturedFrame) {
        encoder?.invalidate(); decoder?.invalidate(); decoder = nil; decoderConfig = nil
        codecNotice = nil; encodeFailures = 0
        do {
            let e = try VideoEncoder(width: frame.pixelWidth, height: frame.pixelHeight, preferred: .hevc, bitsPerSecond: Int(qualityMbps * 1_000_000))
            e.onFrame = { [weak self] f in Task { @MainActor in self?.handleEncoded(f) } }
            // Set before the first encode. It runs on a VideoToolbox queue, or on this thread inside `encode` and
            // `setBitrate`, and a setting rejected inside `init` arrives the moment it is set: so it hops to the main actor.
            e.onError = { [weak self] err in Task { @MainActor in self?.handleCodecError(err) } }
            encoder = e
            codecLabel = e.codec == .hevc ? "HEVC" : "H.264"
        } catch {
            state = .failed("Hardware video encoder unavailable: \(error)")
        }
    }

    private func handleEncoded(_ f: EncodedFrame) {
        let now = CACurrentMediaTime()
        encodeFailures = 0
        telemetry.recordBytes(f.data.count, at: now)
        if let cfg = f.videoConfig, cfg != decoderConfig {
            do { decoder = try VideoDecoder(config: cfg); decoderConfig = cfg } catch { state = .failed("Decoder: \(error)"); return }
            decoder?.onFrame = { [weak self] d in Task { @MainActor in self?.handleDecoded(d) } }
            decoder?.onError = { [weak self] err in Task { @MainActor in self?.handleCodecError(err, from: "decoder") } }
        }
        guard let decoder else { return }
        do { try decoder.decode(f.videoFrame) } catch { telemetry.recordDrop(at: now); decoder.invalidate(); self.decoder = nil; decoderConfig = nil; encoder?.requestKeyframe() }
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
            if encodeFailures >= 10 { failEncoding() }
        case .property(let key, let status):
            codecNotice = "The video \(part) rejected its \(key) setting (\(status)); the picture goes on without it."
        case .sessionCreate, .decode, .formatDescription, .prepare:
            codecNotice = "Video \(part): \(error)"   // Task 9 throws these instead; shown all the same if one ever arrives
        }
    }

    /// The encoder is not coming back by itself: stop it, keep the raw picture, offer Retry (a fresh session and encoder).
    private func failEncoding() {
        log.error("the video encoder failed 10 frames in a row")
        encoder?.invalidate(); decoder?.invalidate(); encoder = nil; decoder = nil; decoderConfig = nil
        encodeFailures = 0; codecLabel = "raw"; codecMs = nil; encodeStarts.removeAll()
        state = .failed("Video encoding keeps failing.")
    }

    private func handleDecoded(_ d: DecodedFrame) {
        if let start = encodeStarts.removeValue(forKey: d.seq) { codecWindow.add((CACurrentMediaTime() - start) * 1000, at: CACurrentMediaTime()) }
        if encodeStarts.count > 120 { encodeStarts.removeAll() }
        sink.push(d.pixelBuffer, captureHostTimeNs: d.captureHostTimeNs, compareWith: latestRaw?.pixelBuffer, dividerAt: dividerPosition)
    }

    private func loopbackDidChange() {
        if !loopback {
            encoder?.invalidate(); decoder?.invalidate(); encoder = nil; decoder = nil; decoderConfig = nil
            codecLabel = "raw"; codecMs = nil; encodeStarts.removeAll(); codecNotice = nil; encodeFailures = 0
        }
    }

    private func handle(_ event: CaptureEvent) {
        switch event {
        case .started(let w, let h, let s):
            pixelSize = CGSize(width: w, height: h); scale = s; state = .capturing
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
