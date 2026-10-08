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
            case .enteringCode(let peer): codeEntry(peer)
            case .connecting(let peer): message("Connecting to \(peer.name)…", action: nil)
            case .connected: connected(overlay: nil)
            case .reconnecting(_, let attempt): connected(overlay: "Reconnecting… attempt \(attempt)")
            case .failed(let text, _): message(text, action: ("Try again", model.retry))
            }
        }
        .background(Theme.Colors.background)
    }

    private var browsing: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MACS SHARING ON THIS NETWORK").font(Theme.Fonts.smallCaps(10)).foregroundStyle(Theme.Colors.muted).tracking(1.5)
            if let notice = model.discoveryNotice {
                Text(notice).font(.system(size: 13)).foregroundStyle(Theme.Colors.text).padding(.vertical, 20)
            } else if model.peers.isEmpty {
                Text("Looking for Macs running Nítido…").font(.system(size: 13)).foregroundStyle(Theme.Colors.text).padding(.vertical, 20)
            }
            ForEach(model.peers) { peer in
                Button { model.select(peer) } label: {
                    HStack { Text(peer.name).font(.system(size: 14, weight: .medium)); Spacer(); Image(systemName: "chevron.right") }
                        .foregroundStyle(Theme.Colors.text).padding(12)
                        .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
                }.buttonStyle(.plain)
            }
        }
        .padding(32).frame(width: 520, alignment: .leading)
    }

    private func codeEntry(_ peer: Peer) -> some View {
        VStack(spacing: 14) {
            Text(peer.name).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.Colors.text)
            Text("ENTER THE 4-DIGIT CODE SHOWN ON THAT MAC").font(Theme.Fonts.smallCaps(10)).foregroundStyle(Theme.Colors.muted).tracking(1.5)
            TextField("0000", text: $model.code)
                .textFieldStyle(.plain).font(Theme.Fonts.figures(34)).multilineTextAlignment(.center)
                .foregroundStyle(Theme.Colors.gold).frame(width: 160)
                .onChange(of: model.code) { _, v in model.code = String(v.filter(\.isNumber).prefix(4)) }
                .onSubmit { model.connect() }
            HStack(spacing: 12) {
                Button("Back") { model.disconnect() }
                Button("Connect") { model.connect() }.keyboardShortcut(.defaultAction).disabled(model.code.count != 4)
            }
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
                HStack(spacing: 6) {
                    Circle().fill(Theme.Colors.success).frame(width: 6, height: 6)
                    Text(model.sharerName).font(.system(size: 11)).foregroundStyle(Theme.Colors.text)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Theme.Colors.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
                .padding(14)
            }
            .frame(width: size.width, height: size.height, alignment: .topTrailing)
            .frame(width: area.width, height: area.height, alignment: .topLeading)
            if model.showTelemetry {
                TelemetryStrip(snapshot: model.snapshot, resolution: model.resolutionLabel, codec: model.codecLabel, latencyLabel: "glass→glass (est.)")
            }
        }
        .frame(width: area.width)
    }

    private func notice(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Theme.Colors.text)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Theme.Colors.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: Theme.controlRadius))
    }

    private func message(_ text: String, action: (String, () -> Void)?) -> some View {
        VStack(spacing: 14) {
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.Colors.text).multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Back") { model.disconnect() }
                if let action { Button(action.0, action: action.1).keyboardShortcut(.defaultAction) }
            }
        }
        .padding(40).frame(width: 520)
    }
}
