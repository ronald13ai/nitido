import SwiftUI
import NitidoCore
import NitidoLink

public struct ViewView: View {
    @Bindable var model: ViewModel
    public init(model: ViewModel) { self.model = model }

    public var body: some View {
        Group {
            switch model.state {
            case .browsing: browsing
            // One branch for both: the code field stays the same view while the code is tried, so a wrong code shakes
            // it in place. A field made anew on the way back from a separate Connecting screen never sees
            // `wrongCodeCount` change, and would not shake.
            case .enteringCode(let peer), .connecting(let peer): codeEntry(peer)
            // One branch for both as well: the picture, the ink and the sharer's chip stay through a reconnect, so the
            // gold ring draws again when the link is ready again (`connectionCount`), not when it drops.
            case .connected, .reconnecting: connected(overlay: reconnectingText)
            case .failed(let text, _): failure(text)
            }
        }
        .background(Theme.Colors.background)
    }

    private var reconnectingText: String? {
        if case .reconnecting(_, let attempt) = model.state { return "Reconnecting… attempt \(attempt)" }
        return nil
    }

    private var browsing: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MACS SHARING ON THIS NETWORK").font(Theme.Fonts.smallCaps(10)).foregroundStyle(Theme.Colors.secondaryText).tracking(1.5)
            if let notice = model.discoveryNotice {
                Text(notice).font(.system(size: 13)).foregroundStyle(Theme.Colors.text).padding(.vertical, 20)
            } else if model.peers.isEmpty {
                Text("Looking for Macs running Nítido…").font(.system(size: 13)).foregroundStyle(Theme.Colors.text).padding(.vertical, 20)
            }
            ForEach(Array(model.peers.enumerated()), id: \.element.id) { index, peer in
                Button { model.select(peer) } label: {
                    HStack { Text(peer.name).font(.system(size: 14, weight: .medium)); Spacer(); Image(systemName: "chevron.right") }
                        .foregroundStyle(Theme.Colors.text).padding(12)
                        .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
                }
                .buttonStyle(PressFeedback())
                .appear(delay: Double(index) * Theme.Motion.stagger)
            }
        }
        .padding(32).frame(width: 520, alignment: .leading)
    }

    /// Also the Connecting screen (`body`): the field stays put while the code is tried, and Back still leaves.
    private func codeEntry(_ peer: Peer) -> some View {
        let connecting = model.state == .connecting(peer)
        let canConnect = model.code.count == 4 && !connecting
        return VStack(spacing: 14) {
            Text(peer.name).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.Colors.text)
            Text("ENTER THE 4-DIGIT CODE SHOWN ON THAT MAC").font(Theme.Fonts.smallCaps(10)).foregroundStyle(Theme.Colors.secondaryText).tracking(1.5)
            TextField("0000", text: $model.code)
                .textFieldStyle(.plain).font(Theme.Fonts.figures(34)).multilineTextAlignment(.center)
                .foregroundStyle(Theme.Colors.gold).frame(width: 160)
                // Digits of any script become ASCII digits (the key is derived from them); nothing else gets in.
                .onChange(of: model.code) { _, v in
                    let typed = ViewModel.normalizedCode(v)
                    if typed != v { model.code = typed }
                }
                .onSubmit { model.connect() }
                .shake(trigger: model.wrongCodeCount)
            // One line, always there so nothing below moves: what the code is doing, or that it was wrong. Gold, as
            // every warning in Nítido is; soft red is for the destructive confirmation only.
            Text(connecting ? "Connecting to \(peer.name)…" : model.wrongCodeCount > 0 ? "Wrong code" : " ")
                .font(.system(size: 12)).foregroundStyle(connecting ? Theme.Colors.text : Theme.Colors.gold)
            HStack(spacing: 12) {
                QuietButton("Back") { model.disconnect() }
                GoldButton("Connect") { model.connect() }.disabled(!canConnect).opacity(canConnect ? 1 : 0.4)
            }
            // ⏎ connects: the gold button draws its own shape, so the default action sits on a hidden system button.
            .background(DefaultAction { model.connect() })
        }
        .padding(40).frame(width: 520)
    }

    /// Laid out like `ShareView` (Task 8 fix round 3): the content is exactly as wide as the picture, to the whole
    /// point, so `.windowResizability(.contentSize)` fits the window to every stream size, smaller ones included,
    /// and the strip wraps instead of widening it. A half-point 1:1 picture keeps its exact size at the top left.
    private func connected(overlay: String?) -> some View {
        let size = model.fittedPointSize
        let area = CGSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
        return VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                VideoSurface(sink: model.sink).frame(width: size.width, height: size.height)
                InkOverlay(controller: model.ink).frame(width: size.width, height: size.height)
                if let overlay {
                    Theme.Colors.background.opacity(0.55).frame(width: size.width, height: size.height)
                    Text(overlay).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.Colors.text)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
                        .frame(width: size.width, height: size.height)
                }
                if model.renderFailure != nil || model.codecNotice != nil {
                    VStack(alignment: .leading, spacing: 6) {
                        if let reason = model.renderFailure { notice("The picture cannot be drawn: \(reason)") }
                        if let text = model.codecNotice { notice(text) }
                    }
                    .padding(14)
                    .frame(width: size.width, height: size.height, alignment: .bottomLeading)
                    .allowsHitTesting(false)
                }
                GlassCard {
                    HStack(spacing: 6) {
                        ZStack {
                            Circle().fill(Theme.Colors.success).frame(width: 6, height: 6)
                            ConnectRing(trigger: model.connectionCount, shownFor: $model.ringShownFor).frame(width: 14, height: 14)
                        }
                        Text(model.sharerName).font(.system(size: 11)).foregroundStyle(Theme.Colors.text)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
                .padding(14)
            }
            .frame(width: size.width, height: size.height, alignment: .topTrailing)
            .frame(width: area.width, height: area.height, alignment: .topLeading)
            if model.showTelemetry {
                // The viewer counts frames as they arrive, so its first figure says received, not capture.
                TelemetryStrip(snapshot: model.snapshot, resolution: model.resolutionLabel, codec: model.codecLabel,
                               latencyLabel: "glass→glass (est.)", captureLabel: "received")
            }
        }
        .frame(width: area.width)
    }

    private func notice(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Theme.Colors.text)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Theme.Colors.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: Theme.controlRadius))
    }

    /// A decoder failure offers Reconnect, to the same Mac with the same code (spec 12); any other, Try again, which goes
    /// back to the code for that Mac (or the list).
    private func failure(_ text: String) -> some View {
        let reconnects = model.failureOffersReconnect
        let action = reconnects ? model.reconnect : model.retry
        return VStack(spacing: 14) {
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.Colors.text).multilineTextAlignment(.center)
            HStack(spacing: 12) {
                QuietButton("Back") { model.disconnect() }
                QuietButton(reconnects ? "Reconnect" : "Try again", action: action)
            }
            // ⏎ does the same, as the system button it replaces did.
            .background(DefaultAction(action: action))
        }
        .padding(40).frame(width: 520)
    }
}

/// The default action (⏎) for a screen whose buttons draw themselves (`GoldButton`, `QuietButton`): an invisible
/// system button that takes no room, like `EscapeStops`.
private struct DefaultAction: View {
    let action: () -> Void
    var body: some View {
        Button("", action: action)
            .keyboardShortcut(.defaultAction)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }
}
