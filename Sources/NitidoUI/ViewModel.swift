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
    public var showTelemetry = true
    public let sink = FrameSink()
    public let ink = InkController(role: .view)
    public let name = Host.current().localizedName ?? "Mac"

    /// Internal, not private, so a test can drive discovery's states.
    let browser = Browser()
    private var link: LinkSession?
    private var linkTasks: [Task<Void, Never>] = []
    private var decoder: VideoDecoder?
    private var decoderConfig: VideoConfig?
    /// Frames the decoder threw on in a row; every third lets the decoder go for a fresh one, ten end the link
    /// (`handleIncoming`). A frame decoded, the session ready again, or leaving, resets it.
    private var decodeFailures = 0
    private var telemetry = Telemetry(now: CACurrentMediaTime())
    private var tasks: [Task<Void, Never>] = []

    public init() {
        ink.onOutgoing = { [weak self] m in self?.link?.send(m) }
        sink.onPresented = { [weak self] captureNs, presentedAt in
            guard let self else { return }
            telemetry.recordDisplay(at: presentedAt)
            if let offset = link?.clockOffsetNs {
                let localCapture = (Double(captureNs) - Double(offset)) / 1e9
                telemetry.recordLatency(ms: max(0, (presentedAt - localCapture) * 1000), at: presentedAt)
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

    public var resolutionLabel: String {
        pixelSize == .zero ? "·" : "\(Int(pixelSize.width))×\(Int(pixelSize.height)) @\(Int(scale))x"
    }

    /// 1:1 when it fits the screen, scaled down otherwise, never up. The same rule as `ShareModel.fittedPointSize`
    /// (`Fit.size`): a 1:1 picture keeps its exact size, half a point included, which `ViewView` lays out at the top
    /// left of a whole-point window; rounding it would scale the picture by a hair and blur every pixel.
    public var fittedPointSize: CGSize {
        guard pixelSize != .zero else { return CGSize(width: 640, height: 400) }
        let natural = sink.view?.pointSize(forPixelSize: pixelSize) ?? CGSize(width: pixelSize.width / scale, height: pixelSize.height / scale)
        // Room on the window's screen for the picture, leaving space for the title bar, the strip and a margin.
        guard let screen = sink.view?.window?.screen ?? NSScreen.main else { return natural }
        return Fit.size(natural: natural, limit: CGSize(width: screen.visibleFrame.width - 40, height: screen.visibleFrame.height - 120))
    }

    /// A new Mac starts the wrong-code count again. The code field is not on screen here (the list is), so the reset
    /// never shakes it; the same holds for `retry`, which comes from a failure screen.
    public func select(_ peer: Peer) { code = ""; wrongCodeCount = 0; state = .enteringCode(peer) }

    public func connect() {
        guard case .enteringCode(let peer) = state, code.count == 4, code.allSatisfy(\.isNumber) else { return }
        let hello = Hello(protocolVersion: protocolVersion, role: .view, name: name, pixelWidth: 0, pixelHeight: 0,
                          scale: Float(NSScreen.main?.backingScaleFactor ?? 2))
        // The name the sharer keyed its listener with (Task 13): Bonjour may show it renamed, as "Name (2)".
        let session = LinkSession(endpoint: peer.endpoint, code: code, sharerName: peer.keyName, hello: hello)
        link?.close()
        link = session
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
        wrongCodeCount = 0
        if case .failed(_, let peer?) = state { state = .enteringCode(peer) } else { state = .browsing }
    }

    public func disconnect() {
        link?.close(); link = nil; linkTasks.forEach { $0.cancel() }; linkTasks = []
        decoder?.invalidate(); decoder = nil; decoderConfig = nil; decodeFailures = 0
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
        case .ready: state = .connected; connectionCount += 1; decodeFailures = 0; link?.send(.keyframeRequest)
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
            do {
                decoder?.invalidate()
                codecNotice = nil
                let d = try VideoDecoder(config: cfg)
                d.onFrame = { [weak self] frame in Task { @MainActor in self?.sink.push(frame.pixelBuffer, captureHostTimeNs: frame.captureHostTimeNs) } }
                // A RealTime setting rejected inside `init` arrives the moment this is set: hop to the main actor.
                d.onError = { [weak self] err in Task { @MainActor in self?.handleDecoderError(err) } }
                decoder = d; decoderConfig = cfg
                pixelSize = CGSize(width: Int(cfg.width), height: Int(cfg.height))
                codecLabel = cfg.codec == .hevc ? "HEVC" : "H.264"
            } catch {
                // Nothing on this link can be shown any more: end it, so it does not go on sending to nobody.
                log.error("could not create the video decoder: \(String(describing: error), privacy: .public)")
                disconnect()
                state = .failed("Could not start the video decoder: \(error)", nil)
            }
        case .videoFrame(let f):
            telemetry.recordCapture(at: now); telemetry.recordBytes(f.data.count, at: now)
            guard let decoder else { link?.send(.keyframeRequest); return }
            do {
                try decoder.decode(f)
                decodeFailures = 0
            } catch {
                // `VideoDecoder.decode` does not log what it throws. A decoder that keeps throwing would freeze the
                // picture without a word and ask for a keyframe on every frame: each throw is logged and counted as
                // dropped, and ten in a row end the link and say so, as on the sharing side (`ShareModel.handleEncoded`).
                // Every third one lets the decoder go: the keyframe asked for carries the video setup, which makes a
                // fresh one (`.videoConfig`).
                log.error("the video decoder could not decode frame \(f.seq, privacy: .public): \(String(describing: error), privacy: .public)")
                telemetry.recordDrop(at: now)
                decodeFailures += 1
                guard decodeFailures < 10 else {
                    log.error("the video decoder failed 10 frames in a row; ending the link")
                    disconnect()
                    state = .failed("Video decoding keeps failing.", nil)
                    return
                }
                if decodeFailures % 3 == 0 { decoder.invalidate(); self.decoder = nil; decoderConfig = nil }
                link?.send(.keyframeRequest)
            }
        case .stroke(let s): ink.applyRemote(s)
        case .undo(let id): ink.undoRemote(id: id)
        case .clear: ink.clearRemote()
        case .cursor(let c): ink.remoteCursor(c, name: sharerName)
        default: break
        }
    }

    /// Decoder failures that are not thrown (Task 9's `onError`); the codec has logged them. A rejected setting leaves
    /// the decoder working, so it is said in a notice over the picture.
    private func handleDecoderError(_ error: CodecError) {
        switch error {
        case .property(let key, let status):
            codecNotice = "The video decoder rejected its \(key) setting (\(status)); the picture goes on without it."
        default:
            codecNotice = "Video decoder: \(error)"
        }
    }
}
