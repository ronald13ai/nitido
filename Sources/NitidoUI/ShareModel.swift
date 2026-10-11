import SwiftUI
import AppKit
import QuartzCore
import NitidoCore
import NitidoCapture
import NitidoCodec
import NitidoLink

/// What the Share window shows. Only what a view reads is observed; the per-frame bookkeeping (the encoder and its
/// counts, the telemetry, the bitrate controller, the links) is `@ObservationIgnored`, so 60 writes a second never go
/// through the observation registrar.
///
/// Its methods live in extensions, one file per responsibility: the capture session (`ShareModel+Capture`), the
/// encoder (`+Codec`), the codec loop (`+Loopback`), the viewers (`+Viewers`), what goes out to them (`+Sending`) and
/// the strip's figures (`+Telemetry`). The state those files share is declared here, internal rather than private,
/// since Swift's `private` stops at the end of a file.
@MainActor @Observable
public final class ShareModel {
    public enum State: Equatable { case idle, picking, capturing, failed(String) }

    /// Display and idle sleep stay off while the share captures, and only then: the viewer's picture freezes when this
    /// Mac's display sleeps, and a sharer watching the viewer's ink touches nothing (`SessionActivity`).
    public internal(set) var state: State = .idle {
        didSet { if state == .capturing { activity.begin("Sharing the screen") } else { activity.end() } }
    }
    /// Internal, not private, so a test can see whether it is held.
    @ObservationIgnored let activity = SessionActivity()
    public internal(set) var snapshot: Snapshot = .empty
    public internal(set) var pixelSize: CGSize = .zero
    public internal(set) var scale: CGFloat = 2
    public var showTelemetry = true
    public let sink = FrameSink()
    public let ink = InkController(role: .share)
    /// Rotates after three wrong codes (`rotateCode`, `HandshakeFailures`).
    public internal(set) var code = Pairing.makeCode()
    public let name = Host.current().localizedName ?? "Mac"
    /// True when the current failure most likely comes from a missing Screen Recording grant, so System Settings is the fix.
    public internal(set) var failureNeedsPermission = false
    /// True when the current failure is Stop Sharing from the menu bar: the card says the share stopped, with a pause
    /// symbol, instead of an error (`ShareView`).
    public internal(set) var failureStoppedFromMenuBar = false
    /// The last reason a frame could not be rendered; cleared by the next frame that reaches the screen.
    public internal(set) var renderFailure: String?
    /// True when Screen Recording was not granted as the picker opened, so the picker screen explains the
    /// system prompt that may follow the pick before macOS shows it.
    public internal(set) var mayAskForScreenRecording = false

    public var loopback = false { didSet { if loopback != oldValue { loopbackDidChange() } } }
    public var qualityMbps: Double = 20 { didSet { qualityDidChange() } }
    /// The quality slider's range, in Mbps: the bitrate controller's own bounds (spec 8), 2 to 60.
    nonisolated static let qualityRange: ClosedRange<Double> = {
        let bounds = BitrateController(initial: 0)
        return Double(bounds.minimum) / 1_000_000...Double(bounds.maximum) / 1_000_000
    }()
    /// Where the comparison splits (0...1). Every decoded frame carries it (`handleDecoded`); a move also reaches the
    /// frame the view keeps, which is drawn again only when the source is still (`FramePacer.moveDivider`).
    public var dividerPosition: Double = 0.5 { didSet { if dividerPosition != oldValue { sink.moveDivider(to: dividerPosition) } } }
    public internal(set) var codecMs: Double?
    public internal(set) var codecLabel = "raw"
    /// Internal, not private, so a test can stand in for VideoToolbox's callbacks on the encoder the share made.
    @ObservationIgnored var encoder: VideoEncoder?
    /// Internal, not private, so a test can hold the loop's decoder queue, as a stall would.
    @ObservationIgnored var decoder: VideoDecoder?
    @ObservationIgnored var decoderConfig: VideoConfig?
    /// The newest captured frame, raw: the left of the comparison while the loop is on. While it is off it is the frame
    /// the view holds (it was pushed raw), so it pins no buffer of its own; turning the loop on encodes it at once,
    /// since a still source sends no frame to start with (`encodeNewestAgain`). Cleared with the session.
    @ObservationIgnored var latestRaw: CapturedFrame?
    /// When the newest frame came (`CACurrentMediaTime`): a still source sends none.
    @ObservationIgnored var lastCaptureAt: CFTimeInterval = 0
    /// When the encoder last took a frame (`CACurrentMediaTime`): a frame it turned away carries no keyframe.
    @ObservationIgnored var lastAcceptedAt: CFTimeInterval = 0
    /// The newest frame was turned away at the encoder's two-in-flight cap, and nothing newer has been taken since: the
    /// next encoder output or frame failure, either of which frees a slot, encodes it (`encodePendingNewest`). Spec
    /// sections 5 and 8: the newest frame is the one that gets through, and a still source would send no other.
    @ObservationIgnored var newestPending = false
    /// The capture time `encodePendingNewest` gives the frame waiting at the cap: the one it was turned away with (its
    /// capture time, or the time it was encoded again over a still source, `encodeNewestAgain`).
    @ObservationIgnored var newestPendingStamp: UInt64?
    /// The pixel count of the encoder a rebuild let go (`rebuildEncoder`): the next one keeps the viewer's rate, and the
    /// failures in a row go on counting, so failures that persist across rebuilds still end the share at ten.
    @ObservationIgnored var rebuiltEncoderPixels: Int?
    /// Bumped by every quality change, loop off and retire, so a pending `qualityRested` for an earlier one does nothing.
    @ObservationIgnored var qualityRestToken: UInt64 = 0
    @ObservationIgnored var encodeStarts: [UInt32: Double] = [:]
    @ObservationIgnored var codecWindow = RollingWindow(seconds: 1)
    /// A codec setting VideoToolbox rejected (`CodecError.property` through `onError`), shown over the picture.
    public internal(set) var codecNotice: String?
    /// Frames the encoder failed or emitted empty in a row; ten fail the share (`handleCodecError`). A frame
    /// VideoToolbox dropped is a dropped frame, and neither counts here nor starts the count again.
    @ObservationIgnored var encodeFailures = 0
    /// Every frame counted as dropped since the model was made. Internal for tests.
    var droppedFramesTotal: Int { telemetry.droppedTotal }
    /// Frames the loop's decoder could not read in a row; ten fail the share (`loopDecodeFailed`). Only a frame decoded
    /// resets it. Internal, not private, so a test can wait for a failure to land.
    @ObservationIgnored var decodeFailures = 0
    /// When the loop last asked the encoder for a keyframe because its decoder skipped frames (`handleEncoded`).
    @ObservationIgnored var loopKeyframeAskedAt: CFTimeInterval?
    /// The share failed because its capture ended (`CaptureEvent.failed`: Stop Sharing in the menu bar, a stream that
    /// stopped, or one that could not start or change). The session's picker is still up, and a new pick from it
    /// (`.started`) resumes the share without Retry. A codec or listener failure does not set it: the stream it leaves
    /// running may report a new size, and that must not clear the failure (`handle`). Cleared once capturing again.
    @ObservationIgnored var captureFailed = false

    public internal(set) var viewerName: String?
    public internal(set) var isSending = false
    /// The viewer's link ended without `bye` (a cut network, a viewer that died): its name stays in the pairing panel as
    /// reconnecting until it pairs again, another viewer pairs, or `reconnectGrace` passes (spec 12, "Link drops").
    public internal(set) var viewerReconnecting = false
    /// How long a dropped viewer is shown as reconnecting. Internal so a test can shorten it.
    @ObservationIgnored var reconnectGrace: Duration = .seconds(30)
    /// Bumped whenever the viewer changes, so a pending grace period for an earlier drop does nothing.
    @ObservationIgnored var reconnectGraceToken: UInt64 = 0
    /// Viewers that proved the code so far: each one draws the gold ring once (`ConnectRing`).
    public internal(set) var connectionCount = 0
    /// The connection the gold ring last played for, so the Share screen shown again draws it at rest (`ConnectRing`).
    @ObservationIgnored public var ringShownFor = 0
    /// The first pick's picker was cancelled: the app goes back to Welcome (`AppModel.startShare`).
    @ObservationIgnored public var onCancelled: (() -> Void)?
    /// Why viewers cannot reach this Mac right now (the listener is waiting), shown over the picture.
    public internal(set) var networkNotice: String?
    /// A Mac on another protocol version proved the code and could not pair (spec 12), shown over the picture until a
    /// viewer pairs or the share stops.
    public internal(set) var viewerNotice: String?
    /// The name Bonjour registered the share under, which viewers see in their list: `name`, or "Name (2)" when another
    /// Mac on the network has that name. Nil while nothing is advertised.
    public internal(set) var advertisedName: String?
    /// Internal, not private, so a test can drive the listener's states.
    @ObservationIgnored var advertiser: Advertiser?
    /// The port the listener bound, once it is ready (logged; tests connect to it directly).
    @ObservationIgnored var listeningPort: UInt16?
    /// The viewer: a connection that proved the code. Only it is sent to and heard from. Internal, not private, so a
    /// test can congest it.
    @ObservationIgnored var link: NitidoLink.Link?
    @ObservationIgnored var linkTasks: [Task<Void, Never>] = []
    /// Connections the listener took that have not proved the code yet, each with the loop that follows its states
    /// (`attach`). Until one does, it may be anybody on the network, so it never touches the viewer.
    @ObservationIgnored var unpaired: [ObjectIdentifier: (link: NitidoLink.Link, states: Task<Void, Never>)] = [:]
    /// How many connections are still proving the code (tests check that none is left behind).
    var unpairedCount: Int { unpaired.count }
    /// Adapts the viewer's bitrate every 250 ms (the snapshot loop), from the RTT, the send backlog and the skips the
    /// dropping rule started (`backlogPolicy`).
    @ObservationIgnored var controller = BitrateController(initial: 20_000_000)
    /// The encoder's rate, which also sizes the backlog dropping rule (`backlogPolicy`).
    @ObservationIgnored var currentBitrate = 20_000_000
    /// One frame's worth of bytes at the current rate: the unit the backlog drains to. Internal for tests.
    var frameBytes: Int { BacklogPolicy.frameBytes(bitsPerSecond: currentBitrate) }
    /// Spec section 8's dropping rule for the viewer's link: when deltas are skipped for the send backlog, and when the
    /// keyframe that ends the skip is asked for (`handleEncoded`, `keyframeAfterDrain`). Each viewer starts it afresh.
    @ObservationIgnored var backlogPolicy = BacklogPolicy()
    /// A viewer just took over (`linkStateChanged`): it has none of the frames the deltas still in the encoder refer to,
    /// so none goes out to it before the keyframe the takeover asked for (`handleEncoded`).
    @ObservationIgnored var viewerNeedsKeyframe = false
    /// The encoder's next sequence number when the viewer took over: a delta from it or later was encoded after the
    /// takeover, so one held back until the keyframe (the half-second limit can hold that keyframe for a viewer that
    /// comes back) is a frame the viewer never sees, a dropped frame. Nil once the keyframe is out, or with no encoder.
    @ObservationIgnored var heldFromSeq: UInt32?
    /// The keyframes forced for the viewer, its own asks and the sharer's (a takeover, the drain after a skip): at most
    /// one per half second (`KeyframeLimiter`, `forceKeyframe`). A new viewer starts it afresh, so its first keyframe
    /// goes at once; a viewer that comes back (the same address) keeps it.
    @ObservationIgnored var forcedKeyframes = KeyframeLimiter()
    /// The address the viewer `forcedKeyframes` counts for came from (`Link.remoteHost`).
    @ObservationIgnored var forcedKeyframesViewer: String?
    /// Bumped whenever `forcedKeyframes` starts afresh, so a keyframe due for an earlier viewer is not forced.
    @ObservationIgnored var forcedKeyframesToken: UInt64 = 0
    /// When a keyframe last went out to the viewer (`CACurrentMediaTime`): a forced one due after it is not needed.
    @ObservationIgnored var keyframeSentAt: CFTimeInterval?
    /// Wrong codes over the whole share, counted per attempt; three rotate it (`rotateCode`).
    @ObservationIgnored var handshakeFailures = HandshakeFailures()
    /// Wrong codes since the code last changed. Internal for tests.
    var wrongCodeAttempts: Int { handshakeFailures.count }
    /// The clock wrong codes are counted by (`HandshakeFailures`). Internal so a test can move it on.
    @ObservationIgnored var handshakeClock: () -> CFTimeInterval = { CACurrentMediaTime() }
    /// The clock the backlog dropping rule reads (`BacklogPolicy`). Internal so a test can move it on.
    @ObservationIgnored var backlogClock: () -> CFTimeInterval = { CACurrentMediaTime() }

    /// The current session's mailbox for every encoder it makes (`makeEncoder`), read in order by one task on the main
    /// actor (`beginSession`): VideoToolbox's callbacks come in the order the frames were encoded, and the deltas reach
    /// the viewer in that order, with each failure or drop between the frames it came between. A task per callback would
    /// keep that order only as long as the main executor runs same-priority tasks first in, first out.
    @ObservationIgnored var encoderOutput: AsyncStream<EncoderOutput>.Continuation?

    let makeSource: @MainActor () -> any CaptureSource
    /// `CGPreflightScreenCaptureAccess` in the app; tests pass a fixed answer.
    let screenRecordingGranted: @MainActor () -> Bool
    /// The session of the current attempt. Each attempt gets a fresh one: a session's streams end for good
    /// once a task iterating them is cancelled, so a retired session is never reused.
    @ObservationIgnored var capture: (any CaptureSource)?
    @ObservationIgnored var excludedWindowIDs: [CGWindowID] = []
    @ObservationIgnored var telemetry = Telemetry(now: CACurrentMediaTime())
    /// When the pong last recorded in the strip's RTT came (`RTTSample.at`), so each pong counts once.
    @ObservationIgnored var rttRecordedAt: Double?
    /// A negative or huge latency was logged once already for this model.
    @ObservationIgnored var reportedClockMismatch = false
    @ObservationIgnored var tasks: [Task<Void, Never>] = []
    /// Bumped by every start and stop, so a start that waited for an earlier stop knows when it was superseded.
    @ObservationIgnored var attempt: UInt64 = 0
    /// Stops of retired sessions, chained in order across every ShareModel. `SCContentSharingPicker.shared`
    /// is one per process, so a new session waits for all of them before it touches the picker; otherwise
    /// a late stop would deactivate the new session's picker or leave an old observer starting streams.
    static var retiring: Task<Void, Never>?

    public convenience init() { self.init(makeSource: { CaptureSession() }) }

    init(makeSource: @escaping @MainActor () -> any CaptureSource,
         screenRecordingGranted: @escaping @MainActor () -> Bool = { CGPreflightScreenCaptureAccess() }) {
        self.makeSource = makeSource
        self.screenRecordingGranted = screenRecordingGranted
        ink.onOutgoing = { [weak self] m in self?.link?.send(m) }
        sink.onPresented = { [weak self] captureNs, presentedAt in
            self?.framePresented(captureNs: captureNs, at: presentedAt)
        }
        sink.onDropped = { [weak self] drop in self?.frameDropped(drop) }
    }

    /// The pairing code and the Codec loop switch belong to a live share (`ShareView`): while picking, or after a failure
    /// (the listener is stopped until Retry), the code would send a viewer looking for a Mac it cannot find, and the
    /// switch would do nothing.
    public var showsLiveControls: Bool { state == .capturing }

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

    /// 1:1 when it fits the screen, scaled down otherwise (VideoView then draws it with Lanczos), never up. Before the
    /// first pick, Welcome's 600 by 400, so the window does not jump while the picker is up.
    public var fittedPointSize: CGSize {
        guard pixelSize != .zero else { return CGSize(width: 600, height: 400) }
        guard let limit = pictureLimit else { return naturalPointSize }
        return Fit.size(natural: naturalPointSize, limit: limit)
    }
}
