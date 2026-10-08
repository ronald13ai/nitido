import SwiftUI
import AppKit
import QuartzCore
import Network
import NitidoCore
import NitidoCodec
import NitidoLink
import os

private let log = Logger(subsystem: "ai.ronar.nitido", category: "view")

@MainActor @Observable
public final class ViewModel {
    public enum State: Equatable {
        case browsing
        case enteringCode(Peer)
        case connecting(Peer)
        case connected
        case reconnecting(Peer, attempt: Int)
        case failed(String, Peer?)
    }

    public private(set) var state: State = .browsing
    public private(set) var peers: [Peer] = []
    public var code = ""
    public private(set) var snapshot: Snapshot = .empty
    public private(set) var pixelSize: CGSize = .zero
    public private(set) var scale: CGFloat = 2
    public private(set) var sharerName = ""
    public private(set) var codecLabel = "·"
    /// A decoder setting VideoToolbox rejected (`CodecError.property` through `onError`), shown over the picture.
    public private(set) var codecNotice: String?
    /// The last reason a frame could not be drawn, shown over the picture; cleared by the next frame that reaches the screen.
    public private(set) var renderFailure: String?
    /// Why the list of Macs may be empty (Local Network off, discovery stopped), shown on the list.
    public private(set) var discoveryNotice: String?
    /// Times the link became ready, the first time and after every reconnect: each draws the gold ring once (`ConnectRing`).
    public private(set) var connectionCount = 0
    /// Codes the chosen Mac turned away in a row: each shakes the code field once and shows "Wrong code".
    public private(set) var wrongCodeCount = 0
    /// The failure is the decoder's (it could not start, or ten frames in a row failed), not the link's: the same Mac
    /// with the same code is the fix, so the failure screen offers Reconnect (`reconnect`) instead of Try again.
    public private(set) var failureOffersReconnect = false
    public var showTelemetry = true
    public let sink = FrameSink()
    public let ink = InkController(role: .view)
    public let name = Host.current().localizedName ?? "Mac"

    /// Internal, not private, so a test can drive discovery's states.
    let browser = Browser()
    private var link: LinkSession?
    /// The Mac of the current session, so a decoder failure can offer to reconnect to it (`reconnect`).
    private var currentPeer: Peer?
    private var linkTasks: [Task<Void, Never>] = []
    private var decoder: VideoDecoder?
    private var decoderConfig: VideoConfig?
    /// Frames the decoder could not read in a row; every third lets the decoder go for a fresh one, ten end the link
    /// (`decodeFailed`). A frame decoded, the session ready again, or leaving, resets it. Internal, not private, so a
    /// test can wait for a failure to land.
    private(set) var decodeFailures = 0
    /// When the viewer last asked the sharer for a keyframe: a decoder that keeps skipping asks again only once a
    /// second has passed (`handleIncoming`).
    @ObservationIgnored private var keyframeAskedAt: CFTimeInterval?
    /// The link is ready, the first time or again, and no keyframe has come since: the decoder has nothing a delta could
    /// refer to, or only the frame from before the drop, so deltas wait for the keyframe asked for (`handleIncoming`).
    @ObservationIgnored private var awaitingKeyframe = false
    private var telemetry = Telemetry(now: CACurrentMediaTime())
    private var tasks: [Task<Void, Never>] = []
    /// A negative or huge glass-to-glass estimate was logged once already on this connection (reset on `.ready`).
    @ObservationIgnored private var reportedClockMismatch = false
    /// The sequence number of the last video frame that arrived: a gap is frames that never did (`handleIncoming`).
    /// Forgotten when the link is ready again and when a new setup makes a new decoder (a new encoder starts at 0).
    @ObservationIgnored private var lastSeq: UInt32?

    public init() {
        ink.onOutgoing = { [weak self] m in self?.link?.send(m) }
        sink.onPresented = { [weak self] captureNs, presentedAt in
            guard let self else { return }
            telemetry.recordDisplay(at: presentedAt)
            if let offset = link?.clockOffsetNs {
                let localCapture = (Double(captureNs) - Double(offset)) / 1e9
                let latencyMs = (presentedAt - localCapture) * 1000
                telemetry.recordLatency(ms: latencyMs, at: presentedAt)
                if latencyMs < 0 || latencyMs > 5_000, !reportedClockMismatch {
                    // The strip shows the estimate as it is; the log says what it means.
                    reportedClockMismatch = true
                    log.error("The clock offset to the sharer looks wrong: a frame shows \(latencyMs, format: .fixed(precision: 1), privacy: .public) ms after its capture time")
                }
            }
            if renderFailure != nil { renderFailure = nil }
        }
        // As on the sharing side (Task 8): a frame that never reaches the screen counts as dropped, and a render
        // failure is said over the picture; the view has logged it. A hidden window is neither.
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
        browser.start()
        let peerUpdates = browser.peers, discovery = browser.states
        tasks = [
            // Weak on every update (Task 8 fix round 1): a whole-loop `guard let self` would keep the model, and
            // with it the browser, alive for good, since only `deinit` stops the browser.
            Task { [weak self] in
                for await list in peerUpdates {
                    guard let self else { return }
                    peers = list
                }
            },
            Task { [weak self] in
                for await s in discovery {
                    guard let self else { return }
                    discoveryStateChanged(s)
                }
            },
            Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard let self else { return }
                    let now = CACurrentMediaTime()
                    if let rtt = link?.lastRTTMs { telemetry.recordRTT(ms: rtt, at: now) }
                    snapshot = telemetry.snapshot(now: now)
                }
            },
        ]
    }

    /// The size figure of the strip, with the scale the picture is shown at when it does not fit the screen (spec 17):
    /// the viewer is where a picture larger than the screen is most common.
    public var resolutionLabel: String {
        let factor = pictureLimit.map { Fit.factor(natural: naturalPointSize, limit: $0) } ?? 1
        return Fit.resolutionLabel(pixelSize: pixelSize, scale: scale, factor: factor)
    }

    /// 1:1 when it fits the screen, scaled down otherwise, never up. The same rule as `ShareModel.fittedPointSize`
    /// (`Fit.size`): a 1:1 picture keeps its exact size, half a point included, which `ViewView` lays out at the top
    /// left of a whole-point window; rounding it would scale the picture by a hair and blur every pixel.
    public var fittedPointSize: CGSize {
        guard pixelSize != .zero else { return CGSize(width: 640, height: 400) }
        guard let limit = pictureLimit else { return naturalPointSize }
        return Fit.size(natural: naturalPointSize, limit: limit)
    }

    /// The picture's point size at 1:1 on the display it is on. The sink says which (SwiftUI observes it, so the window
    /// takes the new size when it moves to a display of another scale); the main display until the view is in a window.
    private var naturalPointSize: CGSize {
        let s = sink.backingScale ?? NSScreen.main?.backingScaleFactor ?? scale
        return CGSize(width: pixelSize.width / s, height: pixelSize.height / s)
    }

    /// Room for the picture on that display's screen, leaving space for the title bar, the strip and a margin.
    private var pictureLimit: CGSize? {
        (sink.visibleFrame ?? NSScreen.main?.visibleFrame).map { Fit.limit(visibleFrame: $0) }
    }

    /// The code as the key needs it: ASCII digits, the first four. A decimal digit of any script (full-width from a
    /// Japanese IME, Arabic-Indic, Persian, Devanagari...) becomes its ASCII digit; anything else (letters,
    /// superscripts, fractions) is dropped. The key is derived from the code's bytes, so the right code typed as
    /// '١٢٣٤' would otherwise fail as a wrong one, and count toward the sharer's rotation.
    nonisolated static func normalizedCode(_ s: String) -> String {
        var digits = ""
        for character in s where digits.count < 4 {
            let scalars = character.unicodeScalars
            guard scalars.count == 1, let scalar = scalars.first, scalar.properties.numericType == .decimal,
                  let value = scalar.properties.numericValue, let digit = Int(exactly: value), (0...9).contains(digit)
            else { continue }
            digits += String(digit)
        }
        return digits
    }

    /// A new Mac starts the wrong-code count again. The code field is not on screen here (the list is), so the reset
    /// never shakes it; the same holds for `retry`, which comes from a failure screen.
    public func select(_ peer: Peer) { code = ""; wrongCodeCount = 0; state = .enteringCode(peer) }

    public func connect() {
        let typed = Self.normalizedCode(code)
        if typed != code { code = typed }
        guard case .enteringCode(let peer) = state, code.count == 4, code.allSatisfy({ ("0"..."9").contains($0) }) else { return }
        let hello = Hello(protocolVersion: protocolVersion, role: .view, name: name, pixelWidth: 0, pixelHeight: 0,
                          scale: Float(NSScreen.main?.backingScaleFactor ?? 2))
        // The name the sharer keyed its listener with (Task 13): Bonjour may show it renamed, as "Name (2)".
        let session = LinkSession(endpoint: peer.endpoint, code: code, sharerName: peer.keyName, hello: hello)
        link?.close()
        link = session
        currentPeer = peer
        failureOffersReconnect = false
        state = .connecting(peer)
        linkTasks.forEach { $0.cancel() }
        // As in Task 13: two plain loops (Swift 6.2 rejects a task group's `@MainActor` child tasks), weak on every
        // element, and only the current session's events count.
        linkTasks = [
            Task { [weak self] in
                for await s in session.states {
                    guard let self, link === session else { return }
                    sessionStateChanged(s, peer: peer)
                }
            },
            Task { [weak self] in
                for await m in session.messages {
                    guard let self, link === session else { return }
                    handleIncoming(m)
                }
            },
        ]
        session.start()
    }

    public func retry() {
        wrongCodeCount = 0; failureOffersReconnect = false
        if case .failed(_, let peer?) = state { state = .enteringCode(peer) } else { state = .browsing }
    }

    /// After a decoder failure (`failureOffersReconnect`): connects to the same Mac again with the code typed, without
    /// going back to the list or the code. A code no longer right lands on the code for that Mac, as any wrong code does.
    public func reconnect() {
        guard case .failed(_, let peer?) = state else { return }
        wrongCodeCount = 0
        state = .enteringCode(peer)
        connect()
    }

    public func disconnect() {
        link?.close(); link = nil; currentPeer = nil; failureOffersReconnect = false
        linkTasks.forEach { $0.cancel() }; linkTasks = []
        decoder?.invalidate(); decoder = nil; decoderConfig = nil; decodeFailures = 0; lastSeq = nil; awaitingKeyframe = false
        ink.clearRemote()
        pixelSize = .zero; codecLabel = "·"; codecNotice = nil; renderFailure = nil; sharerName = ""
        state = .browsing
    }

    /// `disconnect`, and returns once the sharer has been told `bye` (`LinkSession.closeAndWait`): a quit waits for it.
    func disconnectAndWait() async {
        let session = link
        link = nil   // so `disconnect` leaves this session alone: it is closed here, and waited for
        disconnect()
        await session?.closeAndWait()
    }

    deinit { browser.stop() }

    /// Says why the list may stay empty: Local Network off (discovery resumes by itself once it is allowed), or
    /// discovery gone for good, which only leaving and opening View again restarts.
    private func discoveryStateChanged(_ s: Browser.State) {
        switch s {
        case .ready: discoveryNotice = nil
        case .waiting(let reason): discoveryNotice = reason
        case .failed(let reason): discoveryNotice = "Nítido stopped looking for Macs: \(reason) Press Esc, then View, to look again."
        case .stopped: break
        }
    }

    private func sessionStateChanged(_ s: LinkSession.State, peer: Peer) {
        switch s {
        case .connecting(let attempt): if attempt > 1 { state = .reconnecting(peer, attempt: attempt) }
        case .ready:
            state = .connected; connectionCount += 1; decodeFailures = 0; lastSeq = nil; reportedClockMismatch = false
            awaitingKeyframe = true
            askForKeyframe()
        case .reconnecting(let attempt, _): state = .reconnecting(peer, attempt: attempt)
        case .codeRejected:
            // The handshake failed on the keys: the code is wrong. Back to the code for that Mac, where the field
            // shakes and says "Wrong code", instead of a failure screen. Every other way a first attempt fails
            // (refused, unreachable, no answer) arrives as `.closed` with its reason, and says it on a failure screen.
            log.info("the sharer turned the code away")
            wrongCodeCount += 1
            state = .enteringCode(peer)
        case .closed(let reason): state = .failed(reason ?? "Disconnected.", peer)
        }
    }

    /// Internal, not private, so a test can hand it what a peer could send.
    func handleIncoming(_ m: Message) {
        let now = CACurrentMediaTime()
        switch m {
        case .hello(let h):
            // The scale comes from the peer: one that is not a real display scale would trap `resolutionLabel`.
            sharerName = h.name; scale = h.scale.isFinite && (1...8).contains(h.scale) ? CGFloat(h.scale) : 2
        case .videoConfig(let cfg):
            guard cfg != decoderConfig else { return }
            do throws(CodecError) {
                decoder?.invalidate()
                codecNotice = nil
                let d = try VideoDecoder(config: cfg)
                // The decoder works on its own queue. Pictures and failures hop to the main actor through the main
                // queue, which keeps them in decode order (a task each would not).
                d.onFrame = { [weak self, weak d] frame in
                    DispatchQueue.main.async { MainActor.assumeIsolated { if let d { self?.decoded(frame, by: d) } } }
                }
                d.onDecodeFailure = { [weak self, weak d] seq, error in
                    DispatchQueue.main.async { MainActor.assumeIsolated { if let d { self?.decodeFailed(d, seq: seq, error: error) } } }
                }
                // A RealTime setting rejected inside `init` arrives the moment this is set: hop to the main actor.
                d.onError = { [weak self] err in Task { @MainActor in self?.handleDecoderError(err) } }
                decoder = d; decoderConfig = cfg; lastSeq = nil
                pixelSize = CGSize(width: Int(cfg.width), height: Int(cfg.height))
                codecLabel = cfg.codec == .hevc ? "HEVC" : "H.264"
            } catch {
                // Nothing on this link can be shown any more: end it, so it does not go on sending to nobody. A fresh
                // session brings the setup again, so the failure offers to reconnect to the same Mac.
                log.error("could not create the video decoder: \(String(describing: error), privacy: .public)")
                failForDecoder("The video decoder could not start. \(error.plainDescription)")
            }
        case .videoFrame(let f):
            // The strip's first figure on the viewer is frames received (`ViewView` labels it so), not captured.
            telemetry.recordCapture(at: now); telemetry.recordBytes(f.data.count, at: now)
            // Frames the sharer skipped for its backlog, or lost in a drop, never arrive: the gap in the numbers says how
            // many. A larger jump is not a count of frames (a new encoder starts again at 0).
            if let last = lastSeq {
                let gap = f.seq &- last
                if (2..<600).contains(gap) { for _ in 1..<gap { telemetry.recordDrop(at: now) } }
            }
            lastSeq = f.seq
            if awaitingKeyframe {
                // Decoded against the frame from before the drop, it would show a corrupted picture until the keyframe.
                // The keyframe was asked for on `.ready`; again only if a second passes without it.
                guard f.isKey else {
                    if keyframeAskedAt.map({ now - $0 >= 1 }) ?? true { askForKeyframe() }
                    return
                }
                awaitingKeyframe = false
            }
            guard let decoder else { askForKeyframe(); return }
            // Decoded off the main actor (`decoded`, `decodeFailed`), so ink, cursor and the presented handlers the
            // pacer depends on never wait behind a hardware decode.
            if case .skipped(let first) = decoder.submit(f) {
                // The decoder has fallen behind: this frame and every delta up to the next keyframe are dropped. The
                // first one asks for that keyframe; a later one asks again once a second has passed, so a lost request
                // cannot freeze the picture.
                telemetry.recordDrop(at: now)
                if first || keyframeAskedAt.map({ now - $0 >= 1 }) ?? true { askForKeyframe() }
            }
        case .stroke(let s): ink.applyRemote(s)
        case .undo(let id): ink.undoRemote(id: id)
        case .clear: ink.clearRemote()
        case .cursor(let c): ink.remoteCursor(c, name: sharerName)
        default: break
        }
    }

    /// Ends the link over a decoder that cannot go on, and offers Reconnect to the same Mac (spec 12).
    private func failForDecoder(_ message: String) {
        let peer = currentPeer
        disconnect()
        state = .failed(message, peer)
        failureOffersReconnect = peer != nil
    }

    private func askForKeyframe() {
        keyframeAskedAt = CACurrentMediaTime()
        link?.send(.keyframeRequest)
    }

    /// A picture from the decoder, in decode order. A decoder let go since (a new setup, every third failure, the link
    /// ended) shows nothing more.
    private func decoded(_ frame: DecodedFrame, by d: VideoDecoder) {
        guard d === decoder else { return }
        decodeFailures = 0
        sink.push(frame.pixelBuffer, captureHostTimeNs: frame.captureHostTimeNs)
    }

    /// A frame the decoder could not read (`VideoDecoder.onDecodeFailure`, which logged it). A decoder that keeps failing
    /// would freeze the picture without a word and ask for a keyframe on every frame: each failure counts as dropped,
    /// and ten in a row end the link and say so, as on the sharing side (`ShareModel.loopDecodeFailed`). Every third
    /// one lets the decoder go: the keyframe asked for carries the video setup, which makes a fresh one
    /// (`.videoConfig`). A decoder let go already says nothing about the current one.
    private func decodeFailed(_ d: VideoDecoder, seq: UInt32, error: CodecError) {
        guard d === decoder else { return }
        telemetry.recordDrop(at: CACurrentMediaTime())
        decodeFailures += 1
        guard decodeFailures < 10 else {
            log.error("the video decoder failed 10 frames in a row; ending the link")
            failForDecoder("Video decoding keeps failing.")
            return
        }
        if decodeFailures % 3 == 0 { d.invalidate(); decoder = nil; decoderConfig = nil }
        askForKeyframe()
    }

    /// Decoder failures that are not thrown (Task 9's `onError`); the codec has logged them. A rejected setting leaves
    /// the decoder working, so it is said in a notice over the picture.
    private func handleDecoderError(_ error: CodecError) {
        switch error {
        case .property(let key, let status):
            codecNotice = "The video decoder rejected its \(CodecError.settingName(key)) setting (error \(status)); the picture goes on without it."
        default:
            codecNotice = error.plainDescription
        }
    }
}
