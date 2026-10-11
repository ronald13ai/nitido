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

    /// Display and idle sleep stay off from the moment the link is ready until the session ends: through a reconnect,
    /// and never on the list, the code or a failure (`SessionActivity`).
    public private(set) var state: State = .browsing {
        didSet {
            switch state {
            case .connected: activity.begin("Viewing \(currentPeer?.keyName ?? "a shared screen")")
            case .reconnecting:
                activity.begin("Viewing \(currentPeer?.keyName ?? "a shared screen")")
                // The sharer may come back where only AWDL reaches it: discovery looks there too while reconnecting.
                browser.usePeerToPeer(true)
            case .browsing, .enteringCode, .connecting, .failed:
                activity.end()
                browser.usePeerToPeer(true)
            }
        }
    }
    /// Internal, not private, so a test can see whether it is held.
    @ObservationIgnored let activity = SessionActivity()
    /// The sharers discovery lists now. Internal to set, so a test can say what discovery says.
    public internal(set) var peers: [Peer] = [] { didSet { listed.withLock { [peers] in $0 = peers } } }
    /// `peers`, for a session's reconnects off the main actor (`LinkSession`'s `currentPeer`).
    @ObservationIgnored private let listed = OSAllocatedUnfairLock<[Peer]>(initialState: [])
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
    /// The connection the gold ring last played for, so the View screen shown again draws it at rest (`ConnectRing`).
    @ObservationIgnored public var ringShownFor = 0
    /// Codes the chosen Mac turned away in a row: each shakes the code field once and shows "Wrong code".
    public private(set) var wrongCodeCount = 0
    /// The failure is the decoder's (it could not start, or ten frames in a row failed), not the link's: the same Mac
    /// with the same code is the fix, so the failure screen offers Reconnect (`reconnect`) instead of Try again.
    public private(set) var failureOffersReconnect = false
    /// The failure came while a picture was on screen (the link closed or gave up reconnecting): the View screen shows it
    /// over the last frame, dimmed, instead of resizing the window to a card.
    public private(set) var failedOverPicture = false
    /// No retry can help (the sharer runs another protocol version): the failure offers only Back.
    public private(set) var failureIsFinal = false
    public var showTelemetry = true
    public let sink = FrameSink()
    public let ink = InkController(role: .view)
    public let name = Host.current().localizedName ?? "Mac"

    /// The Mac of the current session as the list named it, or the name its hello gave (VoiceOver's "Connected to").
    public var peerName: String { currentPeer?.name ?? sharerName }

    /// Internal, not private, so a test can drive discovery's states.
    let browser = Browser()
    private var link: LinkSession?
    /// The Mac of the current session, so a decoder failure can offer to reconnect to it (`reconnect`).
    private var currentPeer: Peer?
    private var linkTasks: [Task<Void, Never>] = []
    /// Internal, not private, so a test can hold the decoder's queue, as a stall would.
    private(set) var decoder: VideoDecoder?
    private var decoderConfig: VideoConfig?
    /// Frames the decoder could not read in a row; every third lets the decoder go for a fresh one, ten end the link
    /// (`decodeFailed`). A frame decoded, the session ready again, or leaving, resets it. Internal, not private, so a
    /// test can wait for a failure to land.
    private(set) var decodeFailures = 0
    /// When the viewer last asked the sharer for a keyframe. Frames that keep arriving without one (a delta before it,
    /// no decoder, a skip under way) ask again only once a second has passed (`askForKeyframeAtMostOnceASecond`).
    @ObservationIgnored private var keyframeAskedAt: CFTimeInterval?
    /// The link is ready, the first time or again, and no keyframe has come since: the decoder has nothing a delta could
    /// refer to, or only the frame from before the drop, so deltas wait for the keyframe asked for (`handleIncoming`).
    @ObservationIgnored private var awaitingKeyframe = false
    private var telemetry = Telemetry(now: CACurrentMediaTime())
    private var tasks: [Task<Void, Never>] = []
    /// When the pong last recorded in the strip's RTT came (`RTTSample.at`), so each pong counts once.
    @ObservationIgnored private var rttRecordedAt: Double?
    /// A negative or huge glass-to-glass estimate was logged once already on this connection (reset on `.ready`).
    @ObservationIgnored private var reportedClockMismatch = false
    /// The sequence number of the last video frame that arrived: a gap is frames the sharer numbered and never sent
    /// (`handleIncoming`). Forgotten when the link is ready again and when a new setup makes a new decoder (a new
    /// encoder starts at 0), so frames lost with a drop never count.
    @ObservationIgnored private var lastSeq: UInt32?

    public convenience init() { self.init(startingDiscovery: true) }

    /// `startingDiscovery` false leaves the Bonjour browser unstarted, so a test that hands it states (`browser`) is
    /// not raced by the real browser's own (its `.ready` clearing a notice the test just set).
    init(startingDiscovery: Bool) {
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
            case .backlog, .noDrawable, .notPresented, .replaced:
                telemetry.recordDrop(at: CACurrentMediaTime())
            case .failed(let reason):
                telemetry.recordDrop(at: CACurrentMediaTime())
                if renderFailure != reason { renderFailure = reason }
            }
        }
        if startingDiscovery { browser.start() }
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
                    // Each pong once: this loop runs twice as often as pings go out.
                    if let rtt = link?.lastRTTSample, rtt.at != rttRecordedAt { rttRecordedAt = rtt.at; telemetry.recordRTT(ms: rtt.ms, at: rtt.at) }
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
        // Under the name the sharer keyed its listener with (Task 13; Bonjour may show it renamed, as "Name (2)"), through
        // the address it published first on this Mac's networks (`Peer.routes(on:)`), as discovery says at each attempt:
        // a sharer that relaunched or rotated its code listens on a new port, and publishes it.
        let listed = listed
        // What discovery last said about this sharer: each attempt looks for it from there (`follow`).
        let seen = OSAllocatedUnfairLock(initialState: peer)
        let session = LinkSession(peer: Self.follow(seen, in: peers) ?? peer, code: code, hello: hello,
                                  currentPeer: { Self.follow(seen, in: listed.withLock { $0 }) ?? seen.withLock { $0 } },
                                  isListed: { Self.follow(seen, in: listed.withLock { $0 }) != nil })
        link?.close()
        link = session
        currentPeer = peer
        failureOffersReconnect = false; failedOverPicture = false; failureIsFinal = false
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

    /// What discovery says now about `peer`, chosen from the list earlier (`listing`), or `peer` as it was chosen once the
    /// list no longer has it.
    nonisolated static func latest(_ peer: Peer, in list: [Peer]) -> Peer { listing(of: peer, in: list) ?? peer }

    /// `seen`, what discovery last said about a session's sharer, looked for in `list` (`listing`) and brought up to date
    /// when found: a sharer renamed, on a new port or with a new address since it was chosen is still recognised by what
    /// it published last. Nil when `list` no longer has it.
    nonisolated static func follow(_ seen: OSAllocatedUnfairLock<Peer>, in list: [Peer]) -> Peer? {
        seen.withLock { last in
            guard let found = listing(of: last, in: list) else { return nil }
            last = found
            return found
        }
    }

    /// `peer`'s entry in `list`, by what it published: the one with its id (a sharer whose code rotated listens on a new
    /// port, and publishes it); else, under its key name, the one on its port at an address it published (the same
    /// listener, its service renamed); else the one at an address it published (the same Mac relaunched, on a new port
    /// with a new code, which the reconnect then asks for). Bonjour renames a service that comes back: two Macs left at
    /// the default name list as "MacBook Pro" and "MacBook Pro (2)", and the one viewed, relaunched after the other left,
    /// comes back as "MacBook Pro" under another id. Another Mac of that name publishes other addresses and is never
    /// taken for it: dialled with this code, it would count a wrong code, and the viewer would say its code changed
    /// instead of, once the Mac viewed has left discovery for 30 s, that it is no longer sharing. Only when the addresses
    /// cannot tell them apart (one side published none) is the one entry with that key name taken; a code that no longer
    /// pairs there says the code changed. Nil when the list has none of these, or more than one.
    nonisolated static func listing(of peer: Peer, in list: [Peer]) -> Peer? {
        if let same = list.first(where: { $0.id == peer.id }) { return same }
        let named = list.filter { $0.keyName == peer.keyName }
        let atItsAddress = named.filter { $0.addresses.contains(where: peer.addresses.contains) }
        if let port = peer.port, let renamed = atItsAddress.first(where: { $0.port == port }) { return renamed }
        if !atItsAddress.isEmpty { return atItsAddress.count == 1 ? atItsAddress[0] : nil }
        let untold = named.filter { $0.addresses.isEmpty || peer.addresses.isEmpty }
        return untold.count == 1 ? untold[0] : nil
    }

    public func retry() {
        wrongCodeCount = 0; failureOffersReconnect = false; failedOverPicture = false; failureIsFinal = false
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
        endSession()
        ink.clearRemote(); ink.hideRemoteCursor()
        pixelSize = .zero; codecLabel = "·"; codecNotice = nil; renderFailure = nil; sharerName = ""
        state = .browsing
    }

    /// Closes the link and lets the decoder go, and leaves the picture as it is: its size, the sharer's name and the
    /// frame the view keeps (`failForDecoder` shows its failure over it).
    private func endSession() {
        link?.close(); link = nil; currentPeer = nil; failureOffersReconnect = false; failedOverPicture = false; failureIsFinal = false
        linkTasks.forEach { $0.cancel() }; linkTasks = []
        decoder?.invalidate(); decoder = nil; decoderConfig = nil; decodeFailures = 0; lastSeq = nil; awaitingKeyframe = false
    }

    /// `disconnect`, and returns once the sharer has been told `bye` (`LinkSession.closeAndWait`): a quit waits for it.
    func disconnectAndWait() async {
        let session = link
        link = nil   // so `disconnect` leaves this session alone: it is closed here, and waited for
        disconnect()
        await session?.closeAndWait()
        if let slow = slowGoodbyeForTesting { try? await Task.sleep(for: slow) }
    }

    /// Test only: how much longer `disconnectAndWait` takes once the bye is out, as over a link whose send does not
    /// complete and waits for its one-second fallback (`Link.close`), so a test can tell goodbyes said together from
    /// goodbyes said one after the other (`AppModel.stop`).
    @ObservationIgnored var slowGoodbyeForTesting: Duration?

    deinit { browser.stop() }

    /// Says why the list may stay empty: Local Network off (discovery resumes by itself once it is allowed), or
    /// discovery gone for good, which only leaving and opening View again restarts.
    private func discoveryStateChanged(_ s: Browser.State) {
        switch s {
        case .ready: discoveryNotice = nil
        case .waiting(let reason): discoveryNotice = reason
        case .failed(let reason): discoveryNotice = "Nítido stopped looking for Macs. \(reason) Press Esc, then View, to look again."
        case .stopped: break
        }
    }

    private func sessionStateChanged(_ s: LinkSession.State, peer: Peer) {
        switch s {
        case .connecting(let attempt): if attempt > 1 { state = .reconnecting(peer, attempt: attempt) }
        case .ready:
            // Through an address the sharer published, the link is off AWDL, and so is discovery from now on: a peer-to-peer
            // browse keeps the Wi-Fi radio hopping to AWDL's channels, which costs the link latency. Through the Bonjour
            // service the sharer may be reachable over AWDL alone, so discovery keeps it.
            let throughAddress = link?.readyThroughPublishedAddress ?? false
            state = .connected; connectionCount += 1; decodeFailures = 0; lastSeq = nil; reportedClockMismatch = false
            browser.usePeerToPeer(!throughAddress)
            awaitingKeyframe = true
            askForKeyframe()
        case .reconnecting(let attempt, _):
            // A stroke the sharer was drawing gets no `.end` over the dropped link: it fades like an ended one.
            ink.endRemoteStrokes()
            state = .reconnecting(peer, attempt: attempt)
        case .codeRejected:
            // The handshake failed on the keys: the code is wrong. Back to the code for that Mac, where the field
            // shakes and says "Wrong code", instead of a failure screen. Every other way a first attempt fails
            // (refused, unreachable, no answer) arrives as `.closed` with its reason, and says it on a failure screen.
            log.info("the sharer turned the code away")
            wrongCodeCount += 1
            state = .enteringCode(peer)
        case .incompatible(let version):
            // Spec 12: both versions named, and the one fix.
            let theirs = version.map { " (protocol \($0); this Mac speaks \(protocolVersion))" } ?? ""
            failureIsFinal = true
            state = .failed("\(peer.keyName) runs a different version of Nítido\(theirs). Update both Macs.", peer)
        case .closed(let reason):
            ink.endRemoteStrokes()
            switch state {
            case .connected, .reconnecting: failedOverPicture = pixelSize != .zero
            default: break
            }
            state = .failed(reason ?? "Disconnected.", peer)
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
                // The decoder works on its own queue. Its pictures, failures and superseded frames reach the main actor
                // in decode order through an outbox where only the newest picture waits (`DecoderOutbox`).
                DecoderOutbox { [weak self, weak d] output in
                    guard let self, let d else { return }
                    decoderOutput(output, from: d)
                }.attach(to: d)
                // A RealTime setting rejected inside `init` arrives the moment this is set: hop to the main actor.
                d.onError = { [weak self] err in Task { @MainActor in self?.handleDecoderError(err) } }
                decoder = d; decoderConfig = cfg; lastSeq = nil
                pixelSize = CGSize(width: Int(cfg.width), height: Int(cfg.height))
                codecLabel = cfg.codec == .hevc ? "HEVC" : "H.264"
            } catch {
                // Nothing on this link can be shown any more: end it, so it does not go on sending to nobody. A fresh
                // session brings the setup again, so the failure offers to reconnect to the same Mac.
                log.error("could not create the video decoder: \(String(describing: error), privacy: .public)")
                failForDecoder("The video decoder could not start\(error.statusNote); reconnect to try again.")
            }
        case .videoFrame(let f):
            // The strip's first figure on the viewer is frames received (`ViewView` labels it so), not captured.
            telemetry.recordCapture(at: now); telemetry.recordBytes(f.data.count, at: now)
            // Frames the sharer numbered and never sent (skipped for its send backlog, or failed in its encoder) leave a
            // gap in the numbers that says how many. A larger jump is not a count of frames (a new encoder starts again
            // at 0). An outage leaves no gap: the link ready again forgets the number (`.ready`).
            if let last = lastSeq {
                let gap = f.seq &- last
                if (2..<600).contains(gap) { for _ in 1..<gap { telemetry.recordDrop(at: now) } }
            }
            lastSeq = f.seq
            if awaitingKeyframe {
                // Decoded against the frame from before the drop, it would show a corrupted picture until the keyframe.
                // The keyframe was asked for on `.ready`; again only if a second passes without it.
                guard f.isKey else { askForKeyframeAtMostOnceASecond(now: now); return }
                awaitingKeyframe = false
            }
            // No decoder: a decode error let it go and asked for the keyframe whose setup makes the next one, which has
            // not come yet. Asked again once a second, not for every frame that arrives meanwhile.
            guard let decoder else { askForKeyframeAtMostOnceASecond(now: now); return }
            // Decoded off the main actor (`decoded`, `decodeFailed`), so ink, cursor and the presented handlers the
            // pacer depends on never wait behind a hardware decode.
            switch decoder.submit(f) {
            case .queued:
                break
            case .fellBehind(let backlog):
                // The oldest frame waiting waited too long (or too many wait): this frame and every delta up to the next
                // keyframe are dropped, and that keyframe drops the frames still waiting (`superseded`). Ask for it now.
                telemetry.recordDrop(at: now)
                log.info("the video decoder fell behind with \(backlog.frames, privacy: .public) frames waiting, the oldest for \(backlog.oldestWait * 1000, format: .fixed(precision: 1), privacy: .public) ms; skipping to the next keyframe")
                askForKeyframe()
            case .skipped:
                // A delta of the skip under way: asks again once a second has passed, so a lost request cannot freeze
                // the picture.
                telemetry.recordDrop(at: now)
                askForKeyframeAtMostOnceASecond(now: now)
            }
        case .stroke(let s): ink.applyRemote(s)
        case .undo(let id): ink.undoRemote(id: id)
        case .clear: ink.clearRemote()
        case .cursor(let c): ink.remoteCursor(c, name: sharerName)
        default: break
        }
    }

    /// Ends the link over a decoder that cannot go on, and offers Reconnect to the same Mac (spec 12). Once a picture has
    /// been on screen the failure shows over its last frame, dimmed, without resizing the window (spec 9), as every other
    /// failure mid-session does; it took the window to the bare 600 by 400 card before.
    private func failForDecoder(_ message: String) {
        let peer = currentPeer
        let overPicture = pixelSize != .zero
        endSession()
        ink.endRemoteStrokes()
        failedOverPicture = overPicture
        state = .failed(message, peer)
        failureOffersReconnect = peer != nil
    }

    private func askForKeyframe() {
        keyframeAskedAt = CACurrentMediaTime()
        link?.send(.keyframeRequest)
    }

    /// Asks unless the last request is under a second old: it may still be on its way, and a sharer that gets several
    /// in a row can send a keyframe for each. Lost, it is asked for again once the second has passed.
    private func askForKeyframeAtMostOnceASecond(now: CFTimeInterval) {
        if keyframeAskedAt.map({ now - $0 >= 1 }) ?? true { askForKeyframe() }
    }

    /// What the decoder handed over (`DecoderOutbox`), in decode order.
    private func decoderOutput(_ output: DecoderOutbox.Output, from d: VideoDecoder) {
        switch output {
        case .frame(let frame): decoded(frame, by: d)
        case .replaced: replaced(by: d)
        case .decodeFailure(let seq, let error): decodeFailed(d, seq: seq, error: error)
        case .superseded: superseded(by: d)
        }
    }

    /// A picture from the decoder, in decode order. A decoder let go since (a new setup, every third failure, the link
    /// ended) shows nothing more.
    private func decoded(_ frame: DecodedFrame, by d: VideoDecoder) {
        guard d === decoder else { return }
        decodeFailures = 0
        sink.push(frame.pixelBuffer, captureHostTimeNs: frame.captureHostTimeNs,
                  pictureSize: CGSize(width: frame.width, height: frame.height))
    }

    /// A picture a newer one replaced before the main actor took it (`DecoderOutbox`): it was decoded, so the failure
    /// count starts again, as for a picture shown, but it never reaches the screen, so it counts as dropped, or as a
    /// pause while the view cannot show frames (`FrameSink.dropped`). A decoder let go already says nothing about the
    /// current one.
    private func replaced(by d: VideoDecoder) {
        guard d === decoder else { return }
        decodeFailures = 0
        sink.dropped(.replaced)
    }

    /// A frame a later keyframe superseded before the decoder reached it (`VideoDecoder.onSuperseded`): it never
    /// reaches the screen, so it counts as dropped. A decoder let go already says nothing about the current one.
    private func superseded(by d: VideoDecoder) {
        guard d === decoder else { return }
        telemetry.recordDrop(at: CACurrentMediaTime())
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
