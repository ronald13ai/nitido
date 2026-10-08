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
    public var showTelemetry = true
    public let sink = FrameSink()
    public let ink = InkController(role: .view)
    public let name = Host.current().localizedName ?? "Mac"

    /// Internal, not private, so a test can drive discovery's states.
    let browser = Browser()
    private var link: NitidoLink.Link?
    private var linkTasks: [Task<Void, Never>] = []
    private var decoder: VideoDecoder?
    private var decoderConfig: VideoConfig?
    /// Frames the decoder threw on in a row; ten end the link (`handleIncoming`). A frame decoded, or leaving, resets it.
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

    public func select(_ peer: Peer) { code = ""; state = .enteringCode(peer) }

    public func connect() {
        guard case .enteringCode(let peer) = state, code.count == 4, code.allSatisfy(\.isNumber) else { return }
        let hello = Hello(protocolVersion: protocolVersion, role: .view, name: name, pixelWidth: 0, pixelHeight: 0,
                          scale: Float(NSScreen.main?.backingScaleFactor ?? 2))
        // The name the sharer keyed its listener with: Bonjour may show it renamed, as "Name (2)".
        let l = NitidoLink.Link.connect(to: peer.endpoint, code: code, sharerName: peer.keyName, hello: hello)
        link?.close()
        link = l
        state = .connecting(peer)
        linkTasks.forEach { $0.cancel() }
        // Two plain loops rather than a task group: Swift 6.2's region checker rejects the group's `@MainActor` child
        // tasks. Weak on every update, like every other model loop (Task 8 fix round 1). Only the current link's events
        // count, as in `ShareModel`: one already on its way when Back (or a new Connect) cancelled the loop would
        // otherwise show a link that is gone as connected, or start a decoder for it.
        linkTasks = [
            Task { [weak self] in
                for await s in l.states {
                    guard let self, link === l else { return }
                    linkStateChanged(s, peer: peer)
                }
            },
            Task { [weak self] in
                for await m in l.messages {
                    guard let self, link === l else { return }
                    handleIncoming(m)
                }
            },
        ]
    }

    public func retry() { if case .failed(_, let peer?) = state { state = .enteringCode(peer) } else { state = .browsing } }

    public func disconnect() {
        link?.close(); link = nil; linkTasks.forEach { $0.cancel() }; linkTasks = []
        decoder?.invalidate(); decoder = nil; decoderConfig = nil; decodeFailures = 0
        ink.clearRemote()
        pixelSize = .zero; codecLabel = "·"; codecNotice = nil; renderFailure = nil; sharerName = ""
        state = .browsing
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

    private func linkStateChanged(_ s: NitidoLink.Link.State, peer: Peer) {
        switch s {
        case .ready: state = .connected; link?.send(.keyframeRequest)
        case .failed(let m):
            log.error("link failed: \(m)")
            state = .failed(state == .connected ? "Connection lost." : "Could not connect. Check the code and try again.", peer)
        case .cancelled: state = .failed("The sharer ended the session.", peer)
        case .connecting: break
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
                log.error("the video decoder could not decode frame \(f.seq, privacy: .public): \(String(describing: error), privacy: .public)")
                telemetry.recordDrop(at: now)
                decodeFailures += 1
                guard decodeFailures < 10 else {
                    log.error("the video decoder failed 10 frames in a row; ending the link")
                    disconnect()
                    state = .failed("Video decoding keeps failing.", nil)
                    return
                }
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
