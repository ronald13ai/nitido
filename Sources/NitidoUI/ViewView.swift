import SwiftUI
import NitidoCore
import NitidoLink

public struct ViewView: View {
    /// The strip's latency label: glass to glass across two Macs, estimated through the clock offset (spec 5). Spelled
    /// out, because the strip's Marcellus has no arrow (`TelemetryStripLabelTests`).
    static let latencyLabel = "glass to glass (est.)"

    /// Every screen without a picture (the list, the code, a failure before any picture) takes Welcome's canvas, so the
    /// window does not jump between unrelated sizes; only the picture sizes the window to the stream.
    static let canvas = CGSize(width: 600, height: 400)

    @Bindable var model: ViewModel
    /// The code field takes typing as soon as it is on screen, and again after a wrong code, without a click.
    @FocusState private var codeFocused: Bool
    /// The code field's ⏎: Connect shows its press, then connects (`GoldButton.submits`).
    @State private var submits = 0
    /// The direction of a change between the list, the code, the picture and a failure (`screen` ranks them).
    @State private var navigation = NavigationBox()
    /// When each Mac in the list was first seen, and how long its row waits, so Macs that appear together stagger
    /// within their batch, never by their place in the list.
    @State private var rows = RowStagger()
    @ReducedMotion private var reduceMotion
    @Environment(\.screenArrival) private var arrival
    public init(model: ViewModel) { self.model = model }

    /// The sharer chip's dot: green while connected, gold (breathing) while reconnecting, as the sharer's own panel
    /// shows its viewer (`PairingPanel`).
    static func sharerDot(_ state: ViewModel.State) -> Color {
        if case .reconnecting = state { return Theme.Colors.gold }
        return Theme.Colors.success
    }

    /// What the screen shows, one branch each, so a change of screen is a transition and a change within one is not.
    private enum Phase: Equatable {
        case list
        /// Entering the code and connecting with it: one branch, so the field stays the same view while the code is
        /// tried and a wrong code shakes it in place. A field made anew on the way back from a separate Connecting
        /// screen never sees `wrongCodeCount` change, and would not shake.
        case code(Peer)
        /// Connected, reconnecting, or failed over the last frame: one branch, so the picture, the ink and the chip
        /// stay through a reconnect (the gold ring draws again when the link is ready again), and a failure keeps the
        /// frame it ended on.
        case picture
        case failure(String)
    }

    private var phase: Phase {
        switch model.state {
        case .browsing: .list
        case .enteringCode(let peer), .connecting(let peer): .code(peer)
        case .connected, .reconnecting: .picture
        case .failed(let text, _): model.failedOverPicture ? .picture : .failure(text)
        }
    }

    /// The phase without its payload: a new peer's code screen is the same screen, not a transition.
    private var screen: Int {
        switch phase { case .list: 0; case .code: 1; case .picture: 2; case .failure: 3 }
    }

    /// The picture area the window is sized to for `model` (`RootView`'s `AnimatedArea`): the stream's area while the
    /// picture is up (connected, reconnecting, or failed over it), the canvas for the list, the code and a failure before
    /// any picture.
    static func area(for model: ViewModel) -> CGSize {
        switch model.state {
        case .connected, .reconnecting: return Fit.area(for: model.fittedPointSize)
        case .failed: return model.failedOverPicture ? Fit.area(for: model.fittedPointSize) : canvas
        case .browsing, .enteringCode, .connecting: return canvas
        }
    }

    /// Screens change by the model alone (a row picked, a network event, Back): their transitions carry their own
    /// timings, and a keyboard path (Esc as Back, `AppModel.requestStop`) turns them off. The window grows to a picture
    /// and closes back around the list with the window curve (`AnimatedArea`, `RootView`).
    public var body: some View {
        let _ = navigation.update(rank: screen, arrival: arrival)
        let staged = navigation.direction == .forward
        ZStack(alignment: .topLeading) {
            switch phase {
            case .list:
                browsing(staged: staged).screenTransition(navigation, staged: true, reduceMotion: reduceMotion)
            case .code(let peer):
                codeEntry(peer, staged: staged).screenTransition(navigation, staged: true, reduceMotion: reduceMotion)
            case .picture:
                // In by its cover and the window's growth, never by a scale; out by a fade.
                picture.transition(AsymmetricTransition(insertion: .identity, removal: .opacity.animation(Theme.Motion.exit.animation)))
            case .failure(let text):
                failureCard(text, overPicture: false)
                    .entrance(.compact, delay: MessageMotion.cardDelay, enabled: staged)
                    .frame(width: Self.canvas.width, height: Self.canvas.height)
                    .screenTransition(navigation, staged: true, reduceMotion: reduceMotion)
            }
        }
        .background(Theme.Colors.background)
        // VoiceOver hears what the screen says, not only what it shows: the shake of a wrong code and the chip's dot are
        // visual alone.
        .onChange(of: Self.announcement(for: model.state, failureTitle: failureTitle)) { _, text in
            if let text { AccessibilityNotification.Announcement(text).post() }
        }
        .onChange(of: model.wrongCodeCount) { _, count in
            if count > 0 { AccessibilityNotification.Announcement("Wrong code").post() }
        }
        .onChange(of: model.connectionCount) { _, count in
            if count > 0 { AccessibilityNotification.Announcement("Connected to \(model.peerName)").post() }
        }
    }

    /// What VoiceOver announces when the View screen's state changes: reconnecting, and each failure with its card's
    /// title (a connection is announced as it is counted, `connectionCount`, since each reconnect that succeeds is one);
    /// nothing for the list and the code, which the person is on already.
    nonisolated static func announcement(for state: ViewModel.State, failureTitle: String) -> String? {
        switch state {
        case .connected: nil
        case .reconnecting(let peer, _): "Reconnecting to \(peer.name)"
        case .failed(let text, _): "\(failureTitle). \(text)"
        case .browsing, .enteringCode, .connecting: nil
        }
    }

    /// The failure card's title for the current failure (`failureCard`).
    private var failureTitle: String {
        if model.failureIsFinal { return "Different versions of Nítido" }
        if model.failureOffersReconnect { return "The picture stopped" }
        if model.failedOverPicture { return "The session ended" }
        return "Could not connect"
    }

    // MARK: The list

    /// The list's entrance (spec 11, M4): the heading at 40 ms, then the rows 40 ms apart from 80 ms (or the empty
    /// state at 80 ms), each rising 6 pt. A Mac that appears later rises in 40 ms after the one before it in the same
    /// update; one that goes fades over 120 ms, and the rows below close the gap over 240 ms.
    enum ListStage {
        static let heading: Double = 0.04
        static let rows: Double = 0.08
    }

    /// The rows scroll inside the canvas: six fill it, and a seventh sharer (an office where several people run Nítido)
    /// was cut off by the window and could not be picked.
    private func browsing(staged: Bool) -> some View {
        let _ = rows.see(model.peers.map(\.id), now: CACurrentMediaTime(), staged: staged)
        return VStack(alignment: .leading, spacing: 0) {
            Text("MACS SHARING ON THIS NETWORK").font(Theme.Fonts.smallCaps(10)).foregroundStyle(Theme.Colors.secondaryText).tracking(1.2)
                .entrance(.row, delay: ListStage.heading, enabled: staged)
            ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.peers, id: \.id) { peer in
                    let slot = rows.slot(for: peer.id)
                    PeerRow(name: peer.name) { model.select(peer) }
                        .entrance(.row, delay: slot.delay, since: slot.since, enabled: slot.animated)
                        .exitTransition(reduceMotion: reduceMotion)
                }
                if let notice = model.discoveryNotice {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(notice).font(.system(size: 13)).foregroundStyle(Theme.Colors.text)
                            .fixedSize(horizontal: false, vertical: true)
                        // The one action that fixes it (spec 9).
                        if LocalNetwork.isOff(notice) {
                            GoldButton("Open System Settings") { NSWorkspace.shared.open(LocalNetwork.settingsURL) }
                        }
                    }
                    .padding(.top, model.peers.isEmpty ? 8 : 16)
                    .entrance(.row, delay: ListStage.rows, enabled: staged)
                } else if model.peers.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Spinner()
                            Text("Looking for Macs sharing on this network").font(.system(size: 13)).foregroundStyle(Theme.Colors.text)
                        }
                        Text("On the other Mac, open Nítido and choose Share.").font(.system(size: 13))
                            .foregroundStyle(Theme.Colors.secondaryText)
                    }
                    .padding(.top, 8)
                    .entrance(.row, delay: ListStage.rows, enabled: staged)
                    .exitTransition(reduceMotion: reduceMotion)
                }
            }
            .padding(.bottom, 8)
            .animation(reduceMotion ? nil : Theme.Motion.move.animation, value: model.peers.map(\.id))
            }
            .scrollIndicators(.automatic)
            .padding(.top, 16)
        }
        .padding(32)
        .frame(width: Self.canvas.width, height: Self.canvas.height, alignment: .topLeading)
    }

    // MARK: The code

    /// The code's entrance (spec 11, M5), once a Mac is picked: the name at 40 ms, the caption at 80 ms, rising 6 pt;
    /// the slots as one group from 0.96 at 120 ms; Back and Connect at 160 ms. The field takes typing from the first
    /// frame. Typing never animates (the digits, the slot's highlight, Connect turning on are the key's echo); connecting
    /// dims the slots to 60 % over 160 ms, a wrong code shakes them once and they come back.
    enum CodeStage {
        static let name: Double = 0.04
        static let caption: Double = 0.08
        static let slots: Double = 0.12
        static let buttons: Double = 0.16
        static let dim = Theme.Motion.hover
        static let dimmed: Double = 0.6
        static let status = Theme.Motion.exit
    }

    /// Also the Connecting screen (`body`): the slots stay put while the code is tried, and Back still leaves. On the
    /// 8 pt grid: name, 8, caption, 24, slots, 16, status, 24, buttons.
    private func codeEntry(_ peer: Peer, staged: Bool) -> some View {
        let connecting = model.state == .connecting(peer)
        let canConnect = model.code.count == 4 && !connecting
        let status = connecting ? "Connecting to \(peer.name)…" : model.wrongCodeCount > 0 ? "Wrong code" : " "
        return VStack(spacing: 0) {
            Text(peer.name).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.Colors.text)
                .entrance(.row, delay: CodeStage.name, enabled: staged)
            Text("ENTER THE 4-DIGIT CODE SHOWN ON THAT MAC").font(Theme.Fonts.smallCaps(10)).foregroundStyle(Theme.Colors.secondaryText).tracking(1.2)
                .padding(.top, 8)
                .entrance(.row, delay: CodeStage.caption, enabled: staged)
            CodeSlots(code: model.code, active: codeFocused && !connecting)
                .opacity(connecting ? CodeStage.dimmed : 1)
                .animation(CodeStage.dim.animation, value: connecting)
                // The field itself is invisible over the slots: it takes the typing, the slots show it.
                .overlay(
                    TextField("", text: $model.code)
                        .textFieldStyle(.plain).font(Theme.Fonts.code(34)).foregroundStyle(.clear).tint(Theme.Colors.gold)
                        .opacity(0.02)
                        .accessibilityLabel("Code")
                        // Digits of any script become ASCII digits (the key is derived from them); nothing else gets in.
                        .onChange(of: model.code) { _, v in
                            let typed = ViewModel.normalizedCode(v)
                            if typed != v { model.code = typed }
                        }
                        .onSubmit { submits += 1 }
                        .focused($codeFocused)
                        .onAppear { codeFocused = true }
                        .onChange(of: model.wrongCodeCount) { codeFocused = true }
                )
                .shake(trigger: model.wrongCodeCount)
                .entrance(.compact, delay: CodeStage.slots, enabled: staged)
                .padding(.top, 24)
            // One line, always there so nothing below moves: what the code is doing, or that it was wrong. Gold, as
            // every warning in Nítido is. It crossfades as it changes.
            Text(status)
                .font(.system(size: 12)).foregroundStyle(connecting ? Theme.Colors.secondaryText : Theme.Colors.gold)
                .contentTransition(.opacity)
                .animation(CodeStage.status.animation, value: status)
                .padding(.top, 16)
            HStack(spacing: 12) {
                QuietButton("Back") { model.disconnect() }
                // ⏎ connects, from the field or not, and Connect shows its press first.
                GoldButton("Connect", isDefault: true, submits: submits) { model.connect() }.disabled(!canConnect)
            }
            .entrance(.compact, delay: CodeStage.buttons, enabled: staged)
            .padding(.top, 24)
        }
        .frame(width: Self.canvas.width, height: Self.canvas.height)
    }

    // MARK: The picture

    /// The picture's entrance on the viewer (spec 11, M7), from its first frame on this connection: the window grows
    /// over 300 ms while the cover fades from 40 ms, the strip rises at 160 ms, the sharer chip comes in at 200 ms, its
    /// dot fills at 240 ms and its ring draws at 260 ms. A reconnect (M10) dims the frozen frame by 20 % and says so in a
    /// pill led by a breathing gold dot; coming back, the ring draws again 80 ms after the link is ready.
    enum PictureStage {
        static let strip: Double = 0.16
        static let chip: Double = 0.20
        static let name: Double = 0.22
        static let dot: Double = 0.24
        static let ring: Double = 0.26
        static let ringAgain: Double = 0.08
        static let pill: Double = 0.04
        static let reconnectDimIn = Theme.Motion.enter.over(0.24)
        static let dimOut = MessageMotion.dimOut
    }

    /// Laid out like `ShareView` (Task 8 fix round 3): the content is exactly as wide as the picture, to the whole
    /// point, so `.windowResizability(.contentSize)` fits the window to every stream size, smaller ones included,
    /// and the strip wraps instead of widening it. A half-point 1:1 picture keeps its exact size at the top left.
    /// A reconnect and a failure both show over the last frame, dimmed.
    private var picture: some View {
        let size = model.fittedPointSize
        // At least `Fit.minimumArea`: a small shared window (a palette, a calculator) sits centred on the background, so
        // the failure card's buttons, the reconnect pill and the sharer chip stay inside the window.
        let area = Fit.area(for: size)
        let origin = Fit.origin(of: size, in: area)
        let since = model.pictureSince
        let reconnecting: Bool = if case .reconnecting = model.state { true } else { false }
        let failure: String? = if case .failed(let text, _) = model.state { text } else { nil }
        let firstConnection = abs((model.connectedSince ?? 0) - (since ?? 0)) < Entrance.grace
        return VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                ZStack(alignment: .topLeading) {
                    VideoSurface(sink: model.sink).frame(width: size.width, height: size.height)
                        .transaction { $0.animation = nil }
                        .accessibilityElement()
                        .accessibilityLabel(model.sharerName.isEmpty ? "Shared screen" : "Screen shared by \(model.sharerName)")
                        .accessibilityAddTraits(.isImage)
                    InkOverlay(controller: model.ink).frame(width: size.width, height: size.height).accessibilityHidden(true)
                        .transaction { $0.animation = nil }
                    PictureCover(since: since).frame(width: size.width, height: size.height).id(since)
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .padding(.leading, origin.x).padding(.top, origin.y)
                .frame(width: area.width, height: area.height, alignment: .topLeading)
                if reconnecting || failure != nil {
                    // One group, flattened, so a sheet over it never leaves the window under it unpainted. The dim is a
                    // solid layer's opacity, never a blur over the live picture: 20 % while the link reconnects (it reads
                    // as paused, the document stays legible), 55 % under a failure card.
                    ZStack {
                        Theme.Colors.background.opacity(failure != nil ? Theme.Motion.failureDim : Theme.Motion.reconnectDim)
                            .animation(MessageMotion.dimIn.animation, value: failure != nil)
                            .entrance(.fade, curve: failure != nil ? MessageMotion.dimIn : PictureStage.reconnectDimIn)
                        if reconnecting {
                            HStack(spacing: 8) {
                                PulseDot(color: Theme.CanvasColors.gold, breathing: true).frame(width: 6, height: 6)
                                Text("Reconnecting…").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.Colors.text)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .glass(in: Capsule(style: .continuous))
                            .entrance(.compact, delay: PictureStage.pill)
                            .exitTransition(outScale: Theme.Motion.screenScale, reduceMotion: reduceMotion)
                        }
                        if let failure {
                            failureCard(failure, overPicture: true)
                                .entrance(.compact, delay: MessageMotion.cardDelay)
                                .exitTransition(outScale: Theme.Motion.screenScale, reduceMotion: reduceMotion)
                        }
                    }
                    .frame(width: area.width, height: area.height)
                    .compositingGroup()
                    .transition(AsymmetricTransition(insertion: .identity, removal: .opacity.animation(PictureStage.dimOut.animation)))
                }
                if failure == nil {
                    NoticeStack(texts: notices, since: since, stageDelay: ShareView.Stage.notices)
                        .padding(16)
                        .frame(width: area.width, height: area.height, alignment: .bottomLeading)
                }
                if failure == nil {
                    HStack(spacing: 6) {
                        PulseDot(color: NSColor(Self.sharerDot(model.state)), breathing: reconnecting)
                            .frame(width: 6, height: 6)
                            .entrance(.scale(0.5), delay: PictureStage.dot - PictureStage.chip, spring: Theme.Motion.alive,
                                      since: since.map { $0 + PictureStage.chip })
                        Text(model.sharerName).font(.system(size: 11)).foregroundStyle(Theme.Colors.text)
                            .entrance(.slide(Theme.Motion.rise), delay: PictureStage.name - PictureStage.chip,
                                      since: since.map { $0 + PictureStage.chip })
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .glass(in: Capsule(style: .continuous))
                    .overlay(ConnectRing(trigger: model.connectionCount, shownFor: $model.ringShownFor, reconnecting: reconnecting,
                                         delay: firstConnection ? PictureStage.ring : PictureStage.ringAgain))
                    .entrance(.scale(Theme.Motion.enterScale, anchor: .topTrailing), delay: PictureStage.chip, since: since)
                    .padding(16)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(reconnecting ? "Reconnecting to \(model.sharerName)" : "Connected to \(model.sharerName)")
                    .exitTransition(reduceMotion: reduceMotion)
                }
            }
            .frame(width: area.width, height: area.height, alignment: .topTrailing)
            // Through a reconnect the strip shows the gap (spec 12); after a failure its figures would only be stale.
            if model.showTelemetry && failure == nil {
                ViewStrip(model: model).entrance(.rise(ShareView.Stage.stripRise), delay: PictureStage.strip, since: since)
            }
        }
        .frame(width: area.width)
    }

    /// What the notices over the picture say now, in order.
    private var notices: [String] {
        var texts: [String] = []
        if let reason = model.renderFailure { texts.append("The picture cannot be drawn: \(reason)") }
        if let text = model.codecNotice { texts.append(text) }
        return texts
    }

    // MARK: Failures

    /// A protocol mismatch offers Back alone: trying again would fail again. A decoder failure offers Reconnect, to the
    /// same Mac with the same code (spec 12); any other, Try again, which goes back to the code for that Mac (or the
    /// list). That is the way forward, gold; Back is quiet.
    private func failureCard(_ text: String, overPicture: Bool) -> some View {
        let back = MessageCard.Action("Back") { model.disconnect() }
        if model.failureIsFinal {
            return MessageCard(symbol: "exclamationmark.triangle", title: "Different versions of Nítido", message: text, actions: [back],
                               overPicture: overPicture)
        }
        if model.failureOffersReconnect {
            return MessageCard(symbol: "exclamationmark.triangle", title: "The picture stopped", message: text,
                               actions: [.init("Reconnect", run: model.reconnect), back], overPicture: overPicture)
        }
        if model.failedOverPicture {
            return MessageCard(symbol: "pause.circle", title: "The session ended", message: text,
                               actions: [.init("Try again", run: model.retry), back], overPicture: overPicture)
        }
        return MessageCard(symbol: "exclamationmark.triangle", title: "Could not connect", message: text,
                           actions: [.init("Try again", run: model.retry), back], overPicture: overPicture)
    }
}

/// The strip for the View screen. Its own view, so only it reads `model.snapshot`, which changes four times a second.
private struct ViewStrip: View {
    let model: ViewModel
    var body: some View {
        // The viewer counts frames as they arrive, so its first figure says received, not capture.
        TelemetryStrip(snapshot: model.stripSnapshot, resolution: model.resolutionLabel, codec: model.codecLabel,
                       latencyLabel: ViewView.latencyLabel, captureLabel: TelemetryStrip.Label.received)
    }
}

/// A Mac in the list: 48 pt tall, a hairline border, the laptop glyph. Under the pointer its fill lifts and its
/// chevron leans 2 pt toward where it leads, over 160 ms, ease; pressed, it gives by 0.985 (a 536 pt row: the same
/// 4 pt of travel a side as a button's 0.97).
private struct PeerRow: View {
    let name: String
    let action: () -> Void
    @State private var hovered = false
    @ReducedMotion private var reduceMotion
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "laptopcomputer").font(.system(size: 15)).foregroundStyle(Theme.Colors.secondaryText)
                    .frame(width: 22).accessibilityHidden(true)
                Text(name).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.Colors.text).lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.Colors.secondaryText)
                    .offset(x: hovered && !reduceMotion ? 2 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 48, maxHeight: 48)
            .background(shape.fill(hovered ? Theme.Colors.hairline.opacity(0.6) : Theme.Colors.surface))
            .overlay(shape.strokeBorder(Theme.Colors.hairline, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(PressFeedback(pressScale: Theme.Motion.pressScaleWide))
        .onHover { inside in withAnimation(Theme.Motion.hover.animation) { hovered = inside } }
    }
}

/// When each Mac in the list was first seen and how long its row waits (spec 11, M4). The Macs listed as the screen
/// comes in stagger 40 ms apart from 80 ms; a batch that appears later staggers within itself from 0, so a Mac that
/// arrives alone rises at once, wherever it lands in the list.
@MainActor
final class RowStagger {
    struct Slot: Equatable { let since: CFTimeInterval; let delay: Double; let animated: Bool }
    private var slots: [String: Slot] = [:]
    private var first = true

    /// Records the Macs listed at `now`; `staged` says whether the screen's own entrance stages (it came forward).
    func see(_ ids: [String], now: CFTimeInterval, staged: Bool) {
        let fresh = ids.filter { slots[$0] == nil }
        let base = first ? ViewView.ListStage.rows : 0
        for (index, id) in fresh.enumerated() {
            slots[id] = Slot(since: now, delay: base + Double(index) * Theme.Motion.stagger, animated: !first || staged)
        }
        first = false
        // A Mac that went and comes back later is a new arrival.
        for id in slots.keys where !ids.contains(id) { slots[id] = nil }
    }

    func slot(for id: String) -> Slot { slots[id] ?? Slot(since: 0, delay: 0, animated: false) }
}

/// The four slots of the code: 44 by 56 pt each, a hairline border, the active one (where the next digit goes) in gold,
/// the digits in the pairing panel's face.
private struct CodeSlots: View {
    let code: String
    let active: Bool
    var body: some View {
        let digits = Array(code)
        HStack(spacing: 12) {
            ForEach(0..<4, id: \.self) { i in
                let shape = RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                let current = active && i == min(digits.count, 3) && digits.count < 4
                Text(i < digits.count ? String(digits[i]) : " ")
                    .font(Theme.Fonts.code(34)).foregroundStyle(Theme.Colors.gold)
                    .frame(width: 44, height: 56)
                    .background(shape.fill(Theme.Colors.surface))
                    // The next slot lights at once: it is the key's echo.
                    .overlay(shape.strokeBorder(current ? Theme.Colors.gold : Theme.Colors.hairline, lineWidth: 1))
            }
        }
        .accessibilityHidden(true)
    }
}

/// A small gold arc that turns while the list looks for Macs (a reconnect breathes a dot instead, `PulseDot`). The system
/// spinner ignores the tint on macOS and would be the one grey moving thing on the screen. Under Reduce Motion the arc
/// stands still.
struct Spinner: View {
    @ReducedMotion private var reduceMotion
    @State private var turning = false
    var body: some View {
        Circle().trim(from: 0, to: 0.72)
            .stroke(Theme.Colors.gold, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .frame(width: 12, height: 12)
            .rotationEffect(.degrees(turning ? 360 : 0))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { turning = true }
            }
            .accessibilityHidden(true)
    }
}
