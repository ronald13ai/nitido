import SwiftUI
import NitidoCore

public struct ShareView: View {
    /// The strip's latency label: exact capture to display on this Mac (spec 10, which writes it "capture→display").
    /// Spelled out, because the strip's Marcellus has no arrow (`TelemetryStripLabelTests`).
    static let latencyLabel = "capture to display"

    @Bindable var model: ShareModel
    public init(model: ShareModel) { self.model = model }

    /// 1:1 when the content fits the screen, scaled down otherwise, never up.
    private var pointSize: CGSize { model.fittedPointSize }

    /// The picture area in whole points. A 1:1 picture with an odd pixel size is a half point wide or tall; a
    /// window cannot be, and rounding it down would cut the picture's last pixel column. So the window gets the
    /// next whole point and the picture keeps its exact size at the top left (1 px of background at most).
    private var areaSize: CGSize { CGSize(width: pointSize.width.rounded(.up), height: pointSize.height.rounded(.up)) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                VideoSurface(sink: model.sink).frame(width: pointSize.width, height: pointSize.height)
                // Above the video, below the divider handle: while the codec loop is on the handle takes the drags, so
                // the ink is drawn with the loop off.
                InkOverlay(controller: model.ink).frame(width: pointSize.width, height: pointSize.height)
                // Covers the whole picture, so it sits below everything that takes a click: the failure's buttons
                // and both panels.
                if model.loopback { DividerHandle(position: $model.dividerPosition).frame(width: pointSize.width, height: pointSize.height) }
                if model.state == .picking { placeholder("Choose a window or a display in the picker.", note: screenRecordingNote) }
                if case .failed(let message) = model.state { failure(message) }
                if model.state == .capturing,
                   model.renderFailure != nil || model.codecNotice != nil || model.networkNotice != nil || model.viewerNotice != nil {
                    VStack(alignment: .leading, spacing: 6) {
                        if let reason = model.renderFailure { notice("The picture cannot be drawn: \(reason)") }
                        if let text = model.codecNotice { notice(text) }
                        if let text = model.networkNotice { notice(text) }
                        if let text = model.viewerNotice { notice(text) }
                    }
                    .padding(14)
                    .frame(width: pointSize.width, height: pointSize.height, alignment: .bottomLeading)
                    .allowsHitTesting(false)
                }
                // The name viewers see in their list ("Mac (2)" when another Mac has this one); the key stays derived
                // from `name`, which the TXT record publishes.
                PairingPanel(name: model.advertisedName ?? model.name, code: model.code, viewer: model.viewerName, reconnecting: model.viewerReconnecting,
                             connectionCount: model.connectionCount, ringShownFor: $model.ringShownFor).padding(14)
                LoopbackPanel(model: model).padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            // The picture area is the picture, whatever an overlay asks for. Top trailing, so an overlay larger than
            // a tiny picture spills left and down and never moves the picture off the window's top left corner.
            .frame(width: pointSize.width, height: pointSize.height, alignment: .topTrailing)
            .frame(width: areaSize.width, height: areaSize.height, alignment: .topLeading)
            if model.showTelemetry {
                TelemetryStrip(snapshot: model.snapshot, resolution: model.resolutionLabel, codec: model.codecLabel,
                               latencyLabel: Self.latencyLabel, codecMs: model.codecMs)
            }
        }
        // As wide as the picture (to the whole point), so `.windowResizability(.contentSize)` fixes the window's
        // width to every pick, narrower ones included, the way it fixes the height; the strip wraps instead of
        // widening it.
        .frame(width: areaSize.width)
        .background(Theme.Colors.background)
    }

    /// Said before the system prompt (spec 12): only when Screen Recording is not granted yet.
    private var screenRecordingNote: String? {
        model.mayAskForScreenRecording
            ? "After you pick, macOS may ask for Screen Recording. Nítido needs it to read the picture you chose and show it here."
            : nil
    }

    /// The first action is the way forward (gold); any other is quiet.
    private func placeholder(_ text: String, note: String? = nil, actions: [(String, () -> Void)] = []) -> some View {
        GlassCard {
            VStack(spacing: 12) {
                Text(text).font(.system(size: 13)).foregroundStyle(Theme.Colors.text).multilineTextAlignment(.center)
                if let note {
                    Text(note).font(.system(size: 12)).foregroundStyle(Theme.Colors.text).multilineTextAlignment(.center)
                }
                if !actions.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(actions.indices, id: \.self) { i in
                            if i == 0 { GoldButton(actions[i].0, action: actions[i].1) } else { QuietButton(actions[i].0, action: actions[i].1) }
                        }
                    }
                }
            }
            .padding(24).frame(maxWidth: 420)
        }
        .frame(width: pointSize.width, height: pointSize.height)
    }

    /// Retry always; System Settings only when the missing Screen Recording grant is the likely cause.
    private func failure(_ message: String) -> some View {
        guard model.failureNeedsPermission else {
            return placeholder(message, actions: [("Retry", model.retry)])
        }
        return placeholder("\(message) Turn on Screen Recording for Nítido in System Settings, then press Retry.",
                           actions: [("Open System Settings", openScreenRecordingSettings), ("Retry", model.retry)])
    }

    /// Said over the last picture instead of failing silently: a frame that cannot be drawn, a codec setting refused.
    private func notice(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12)).foregroundStyle(Theme.Colors.text)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Theme.Colors.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: Theme.controlRadius))
    }

    private func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
    }
}

struct PairingPanel: View {
    let name: String, code: String, viewer: String?
    /// The viewer dropped without `bye` and may come back (`ShareModel.viewerReconnecting`).
    var reconnecting = false
    /// `ShareModel.connectionCount`: the gold ring around the viewer's dot draws once per viewer that proves the code.
    let connectionCount: Int
    /// `ShareModel.ringShownFor`: the connection the ring last played for, so the panel shown again does not replay it.
    @Binding var ringShownFor: Int
    var body: some View {
        GlassCard {
            VStack(alignment: .trailing, spacing: 4) {
                Text(name).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.Colors.text)
                Text("CODE").font(Theme.Fonts.smallCaps(9)).foregroundStyle(Theme.Colors.secondaryText).tracking(1.5)
                Text(code).font(Theme.Fonts.figures(26)).foregroundStyle(Theme.Colors.gold).tracking(4)
                if let viewer {
                    HStack(spacing: 6) {
                        ZStack {
                            // Inactive while the viewer reconnects; the ring draws again once it pairs.
                            Circle().fill(reconnecting ? Theme.Colors.muted : Theme.Colors.success).frame(width: 6, height: 6)
                            ConnectRing(trigger: connectionCount, shownFor: $ringShownFor).frame(width: 14, height: 14)
                        }
                        Text(viewer).font(.system(size: 11)).foregroundStyle(Theme.Colors.text)
                    }.padding(.top, 2)
                    if reconnecting {
                        Text("Reconnecting…").font(.system(size: 11)).foregroundStyle(Theme.Colors.secondaryText)
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
    }
}

struct LoopbackPanel: View {
    @Bindable var model: ShareModel
    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $model.loopback) { Text("Codec loop").font(.system(size: 12, weight: .medium)) }
                    .toggleStyle(.switch).tint(Theme.Colors.gold)
                if model.loopback {
                    Text("QUALITY · \(Int(model.qualityMbps)) MBPS").font(Theme.Fonts.smallCaps(9)).foregroundStyle(Theme.Colors.secondaryText).tracking(1.5)
                    Slider(value: $model.qualityMbps, in: 1...60, step: 1).tint(Theme.Colors.gold).frame(width: 180)
                    Text("Raw on the left of the line, decoded on the right. Drag the line.").font(.system(size: 10)).foregroundStyle(Theme.Colors.secondaryText)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
    }
}

struct DividerHandle: View {
    @Binding var position: Double
    var body: some View {
        GeometryReader { geo in
            Color.clear.contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in position = min(1, max(0, v.location.x / geo.size.width)) })
            // The dot is where a user grabs the line, so it must not take the drag from the handle under it.
            Circle().fill(Theme.Colors.gold).frame(width: 10, height: 10)
                .position(x: geo.size.width * position, y: geo.size.height - 18)
                .allowsHitTesting(false)
        }
    }
}
