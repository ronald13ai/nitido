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
    public init(model: ViewModel) { self.model = model }

    /// The sharer chip's dot: green while connected, the inactive colour while reconnecting, as the sharer's own panel
    /// shows its viewer (`PairingPanel`).
    static func sharerDot(_ state: ViewModel.State) -> Color {
        if case .reconnecting = state { return Theme.Colors.muted }
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

    public var body: some View {
        ZStack {
            switch phase {
            case .list: browsing.screenTransition()
            case .code(let peer): codeEntry(peer).screenTransition()
            case .picture: picture.transition(.opacity)
            case .failure(let text): failureCard(text, overPicture: false).frame(width: Self.canvas.width, height: Self.canvas.height).screenTransition()
            }
        }
        .animation(Theme.Motion.enter, value: screen)
        .background(Theme.Colors.background)
    }

    // MARK: The list

    private var browsing: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("MACS SHARING ON THIS NETWORK").font(Theme.Fonts.smallCaps(10)).foregroundStyle(Theme.Colors.secondaryText).tracking(1.2)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(model.peers.enumerated()), id: \.element.id) { index, peer in
                    PeerRow(name: peer.name) { model.select(peer) }
                        .appear(delay: Double(index) * Theme.Motion.stagger)
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
                }
            }
            .padding(.top, 16)
            .animation(Theme.Motion.enter, value: model.peers.map(\.id))
        }
        .padding(32)
        .frame(width: Self.canvas.width, height: Self.canvas.height, alignment: .topLeading)
    }

    // MARK: The code

    /// Also the Connecting screen (`body`): the slots stay put while the code is tried, and Back still leaves. On the
    /// 8 pt grid: name, 8, caption, 24, slots, 16, status, 24, buttons.
    private func codeEntry(_ peer: Peer) -> some View {
        let connecting = model.state == .connecting(peer)
        let canConnect = model.code.count == 4 && !connecting
        return VStack(spacing: 0) {
            Text(peer.name).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.Colors.text)
            Text("ENTER THE 4-DIGIT CODE SHOWN ON THAT MAC").font(Theme.Fonts.smallCaps(10)).foregroundStyle(Theme.Colors.secondaryText).tracking(1.2)
                .padding(.top, 8)
            CodeSlots(code: model.code, active: codeFocused && !connecting)
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
                .padding(.top, 24)
            // One line, always there so nothing below moves: what the code is doing, or that it was wrong. Gold, as
            // every warning in Nítido is.
            Text(connecting ? "Connecting to \(peer.name)…" : model.wrongCodeCount > 0 ? "Wrong code" : " ")
                .font(.system(size: 12)).foregroundStyle(connecting ? Theme.Colors.secondaryText : Theme.Colors.gold)
                .padding(.top, 16)
            HStack(spacing: 12) {
                QuietButton("Back") { model.disconnect() }
                // ⏎ connects, from the field or not, and Connect shows its press first.
                GoldButton("Connect", isDefault: true, submits: submits) { model.connect() }.disabled(!canConnect)
            }
            .padding(.top, 24)
        }
        .frame(width: Self.canvas.width, height: Self.canvas.height)
    }

    // MARK: The picture

    /// Laid out like `ShareView` (Task 8 fix round 3): the content is exactly as wide as the picture, to the whole
    /// point, so `.windowResizability(.contentSize)` fits the window to every stream size, smaller ones included,
    /// and the strip wraps instead of widening it. A half-point 1:1 picture keeps its exact size at the top left.
    /// A reconnect and a failure both show over the last frame, dimmed.
    private var picture: some View {
        let size = model.fittedPointSize
        let area = CGSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
        let reconnecting: Bool = if case .reconnecting = model.state { true } else { false }
        let failure: String? = if case .failed(let text, _) = model.state { text } else { nil }
        return VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                VideoSurface(sink: model.sink).frame(width: size.width, height: size.height)
                InkOverlay(controller: model.ink).frame(width: size.width, height: size.height)
                if reconnecting || failure != nil {
                    // One group, flattened, so a sheet over it never leaves the window under it unpainted.
                    ZStack {
                        Theme.Colors.background.opacity(0.55)
                        if reconnecting {
                            HStack(spacing: 8) {
                                Spinner()
                                Text("Reconnecting…").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.Colors.text)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .glass(in: Capsule(style: .continuous))
                        }
                        if let failure { failureCard(failure, overPicture: true) }
                    }
                    .frame(width: size.width, height: size.height)
                    .compositingGroup()
                    .transition(.opacity.animation(Theme.Motion.enter))
                }
                if failure == nil, model.renderFailure != nil || model.codecNotice != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        if let reason = model.renderFailure { Notice(text: "The picture cannot be drawn: \(reason)") }
                        if let text = model.codecNotice { Notice(text: text) }
                    }
                    .padding(16)
                    .frame(width: size.width, height: size.height, alignment: .bottomLeading)
                }
                if failure == nil {
                    HStack(spacing: 6) {
                        Circle().fill(Self.sharerDot(model.state)).frame(width: 6, height: 6)
                        Text(model.sharerName).font(.system(size: 11)).foregroundStyle(Theme.Colors.text)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .glass(in: Capsule(style: .continuous))
                    .overlay(ConnectRing(trigger: model.connectionCount, shownFor: $model.ringShownFor, reconnecting: reconnecting))
                    .padding(16)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topTrailing)
            .frame(width: area.width, height: area.height, alignment: .topLeading)
            // Through a reconnect the strip shows the gap (spec 12); after a failure its figures would only be stale.
            if model.showTelemetry && failure == nil { ViewStrip(model: model) }
        }
        .frame(width: area.width)
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
        TelemetryStrip(snapshot: model.snapshot, resolution: model.resolutionLabel, codec: model.codecLabel,
                       latencyLabel: ViewView.latencyLabel, captureLabel: TelemetryStrip.Label.received)
    }
}

/// A Mac in the list: 48 pt tall, a hairline border, the laptop glyph, and a fill that lifts under the pointer over
/// 120 ms.
private struct PeerRow: View {
    let name: String
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "laptopcomputer").font(.system(size: 15)).foregroundStyle(Theme.Colors.secondaryText)
                    .frame(width: 22).accessibilityHidden(true)
                Text(name).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.Colors.text).lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.Colors.secondaryText)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 48, maxHeight: 48)
            .background(shape.fill(hovered ? Theme.Colors.hairline.opacity(0.6) : Theme.Colors.surface))
            .overlay(shape.strokeBorder(Theme.Colors.hairline, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(PressFeedback())
        .onHover { inside in withAnimation(Theme.Motion.hover) { hovered = inside } }
    }
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
                    .overlay(shape.strokeBorder(current ? Theme.Colors.gold : Theme.Colors.hairline, lineWidth: 1))
                    .animation(Theme.Motion.press, value: current)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A small gold arc that turns while something is on its way (the list looking for Macs, a reconnect). The system
/// spinner ignores the tint on macOS and would be the one grey moving thing on the screen. Under Reduce Motion the arc
/// stands still.
struct Spinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
