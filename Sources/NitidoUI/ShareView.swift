import SwiftUI
import NitidoCore

public struct ShareView: View {
    @Bindable var model: ShareModel
    public init(model: ShareModel) { self.model = model }

    /// 1:1 when the content fits the screen, scaled down otherwise, never up.
    private var pointSize: CGSize { model.fittedPointSize }

    public var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                VideoSurface(sink: model.sink).frame(width: pointSize.width, height: pointSize.height)
                if model.state == .picking { placeholder("Choose a window or a display in the picker.") }
                if case .failed(let message) = model.state { failure(message) }
                if model.state == .capturing, let reason = model.renderFailure { renderNotice(reason) }
                PairingPanel(name: model.name, code: model.code).padding(14)
            }
            if model.showTelemetry {
                TelemetryStrip(snapshot: model.snapshot, resolution: model.resolutionLabel, codec: "raw", latencyLabel: "capture→display")
            }
        }
        .background(Theme.Colors.background)
    }

    private func placeholder(_ text: String, actions: [(String, () -> Void)] = []) -> some View {
        VStack(spacing: 12) {
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.Colors.text).multilineTextAlignment(.center)
            if !actions.isEmpty {
                HStack(spacing: 10) {
                    ForEach(actions.indices, id: \.self) { i in Button(actions[i].0, action: actions[i].1) }
                }
            }
        }
        .padding(24).frame(maxWidth: 420)
        .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .frame(width: pointSize.width, height: pointSize.height)
    }

    /// Retry always; System Settings only when the missing Screen Recording grant is the likely cause.
    private func failure(_ message: String) -> some View {
        guard model.failureNeedsPermission else {
            return placeholder(message, actions: [("Retry", model.retry)])
        }
        return placeholder("\(message)\nTurn on Screen Recording for Nítido in System Settings, then press Retry.",
                           actions: [("Open System Settings", openScreenRecordingSettings), ("Retry", model.retry)])
    }

    /// Frames keep arriving but cannot be drawn: say so over the last picture instead of freezing silently.
    private func renderNotice(_ reason: String) -> some View {
        Text("The picture cannot be drawn: \(reason)")
            .font(.system(size: 12)).foregroundStyle(Theme.Colors.text)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Theme.Colors.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: Theme.controlRadius))
            .padding(14)
            .frame(width: pointSize.width, height: pointSize.height, alignment: .bottomLeading)
    }

    private func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
    }
}

struct PairingPanel: View {
    let name: String, code: String
    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(name).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.Colors.text)
            Text("CODE").font(Theme.Fonts.smallCaps(9)).foregroundStyle(Theme.Colors.muted).tracking(1.5)
            Text(code).font(Theme.Fonts.figures(26)).foregroundStyle(Theme.Colors.gold).tracking(4)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.Colors.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(Theme.Colors.hairline, lineWidth: 1))
    }
}
