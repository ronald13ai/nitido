import SwiftUI
import NitidoCore

public struct ShareView: View {
    @Bindable var model: ShareModel
    public init(model: ShareModel) { self.model = model }

    private var pointSize: CGSize {
        guard model.pixelSize != .zero else { return CGSize(width: 720, height: 450) }
        return model.sink.view?.pointSize(forPixelSize: model.pixelSize) ?? CGSize(width: model.pixelSize.width / 2, height: model.pixelSize.height / 2)
    }

    public var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                VideoSurface(sink: model.sink).frame(width: pointSize.width, height: pointSize.height)
                if model.state == .picking { placeholder("Choose a window or a display in the picker.") }
                if case .failed(let message) = model.state { placeholder(message, action: ("Open System Settings", openScreenRecordingSettings)) }
                PairingPanel(name: model.name, code: model.code).padding(14)
            }
            if model.showTelemetry {
                TelemetryStrip(snapshot: model.snapshot, resolution: model.resolutionLabel, codec: "raw", latencyLabel: "capture→display")
            }
        }
        .background(Theme.Colors.background)
    }

    private func placeholder(_ text: String, action: (String, () -> Void)? = nil) -> some View {
        VStack(spacing: 12) {
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.Colors.text).multilineTextAlignment(.center)
            if let action { Button(action.0, action: action.1) }
        }
        .padding(24).frame(maxWidth: 420)
        .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .frame(width: pointSize.width, height: pointSize.height)
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
