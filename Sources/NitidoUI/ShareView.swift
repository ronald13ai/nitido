import SwiftUI
import os
import NitidoCore
import NitidoLink

public struct ShareView: View {
    /// The strip's latency label: exact capture to display on this Mac (spec 10, which writes it "capture→display").
    /// Spelled out, because the strip's Marcellus has no arrow (`TelemetryStripLabelTests`).
    static let latencyLabel = "capture to display"

    @Bindable var model: ShareModel
    public init(model: ShareModel) { self.model = model }

    /// 1:1 when the content fits the screen, scaled down otherwise, never up.
    private var pointSize: CGSize { model.fittedPointSize }

    /// The picture area in whole points, at least `Fit.minimumArea`. A 1:1 picture with an odd pixel size is a half
    /// point wide or tall; a window cannot be, and rounding it down would cut the picture's last pixel column. So the
    /// window gets the next whole point and the picture keeps its exact size at the top left (1 px of background at
    /// most). A picture smaller than the minimum sits centred on the background, and the panels keep to the area.
    private var areaSize: CGSize { Fit.area(for: pointSize) }
    private var pictureOrigin: CGPoint { Fit.origin(of: pointSize, in: areaSize) }

    /// The panels and notices sit 16 pt in from the picture's edges.
    private static let inset: CGFloat = 16

    /// The body reads no figure: the strip is its own view (`ShareStrip`), so the snapshot four times a second
    /// re-evaluates the strip alone, not the panels, the notices and the picture.
    public var body: some View {
        let area = areaSize
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                // The picture, and what lies exactly over it: the ink, and the divider handle, whose drags map to it.
                ZStack(alignment: .topLeading) {
                    VideoSurface(sink: model.sink).frame(width: pointSize.width, height: pointSize.height)
                        .accessibilityElement()
                        .accessibilityLabel("The picture you are sharing")
                        .accessibilityAddTraits(.isImage)
                    // Above the video, below the divider handle: while the codec loop is on the handle takes the drags,
                    // so the ink is drawn with the loop off.
                    InkOverlay(controller: model.ink).frame(width: pointSize.width, height: pointSize.height)
                    // Covers the whole picture, so it sits below everything that takes a click: the failure's buttons
                    // and both panels.
                    if model.loopback {
                        DividerHandle(position: $model.dividerPosition, decoded: "\(model.codecLabel == "raw" ? "HEVC" : model.codecLabel) · \(Int(model.qualityMbps)) Mbps")
                            .frame(width: pointSize.width, height: pointSize.height)
                    }
                }
                .frame(width: pointSize.width, height: pointSize.height, alignment: .topLeading)
                .padding(.leading, pictureOrigin.x).padding(.top, pictureOrigin.y)
                // The rest keeps to the picture area, which a small picture leaves larger than itself.
                if model.state == .picking {
                    MessageCard(symbol: "rectangle.dashed", title: "Choose what to share",
                                message: "Pick a window or a display in the system picker.", note: screenRecordingNote,
                                overPicture: model.pixelSize != .zero)
                        .frame(width: area.width, height: area.height)
                }
                if case .failed(let message) = model.state {
                    // The last picture stays, dimmed, so it does not read as still live (as the viewer's reconnect).
                    Theme.Colors.background.opacity(0.55).frame(width: area.width, height: area.height)
                    failure(message).frame(width: area.width, height: area.height)
                }
                if model.state == .capturing,
                   model.renderFailure != nil || model.codecNotice != nil || model.networkNotice != nil || model.viewerNotice != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        if let reason = model.renderFailure { Notice(text: "The picture cannot be drawn: \(reason)") }
                        if let text = model.codecNotice { Notice(text: text) }
                        if let text = model.networkNotice { Notice(text: text) }
                        if let text = model.viewerNotice { Notice(text: text) }
                    }
                    .padding(Self.inset)
                    .frame(width: area.width, height: area.height, alignment: .bottomLeading)
                }
                // Only over a live share: while picking, or after a failure (the listener is stopped until Retry), the
                // code would send a viewer looking for a Mac it cannot find, and the switch would do nothing.
                if model.showsLiveControls {
                    // The name viewers see in their list ("Mac (2)" when another Mac has this one); the key stays derived
                    // from `name`, which the TXT record publishes.
                    PairingPanel(name: model.advertisedName ?? model.name, code: model.code, viewer: model.viewerName, reconnecting: model.viewerReconnecting,
                                 connectionCount: model.connectionCount, ringShownFor: $model.ringShownFor)
                        .padding(Self.inset)
                        .frame(width: area.width, height: area.height, alignment: .topTrailing)
                    LoopbackPanel(model: model).padding(Self.inset).frame(width: area.width, height: area.height, alignment: .topLeading)
                }
            }
            // The picture area, whatever an overlay asks for.
            .frame(width: area.width, height: area.height, alignment: .topLeading)
            // Only while capturing: while picking, or after a failure, it would show a row of "·" or stale figures.
            if model.showTelemetry && model.state == .capturing { ShareStrip(model: model) }
        }
        // As wide as the picture area (the picture to the whole point, or the minimum), so
        // `.windowResizability(.contentSize)` fixes the window's width to every pick, narrower ones included, the way it
        // fixes the height; the strip wraps instead of widening it.
        .frame(width: area.width)
        .background(Theme.Colors.background)
    }

    /// Said before the system prompt (spec 12): only when Screen Recording is not granted yet.
    private var screenRecordingNote: String? {
        model.mayAskForScreenRecording
            ? "After you pick, macOS may ask for Screen Recording. Nítido needs it to read the picture you chose and show it here."
            : nil
    }

    /// The Screen Recording card's sentence after `message`. A grant reaches a running app only once it relaunches (macOS
    /// offers Quit & Reopen, and Later keeps the old process denied), so the way forward is to quit and reopen, not Retry,
    /// which met the same refusal. And when the switch is on already, the grant belongs to another copy of Nítido signed
    /// by someone else (the zip, then a build of one's own): only removing Nítido from the list and adding it again
    /// gives it to this one.
    nonisolated static let screenRecordingFix = "Turn on Screen Recording for Nítido in System Settings, then quit and reopen Nítido. If it is on already, another copy of Nítido holds it: remove Nítido from the list with the minus button and add it again."

    /// Retry always; System Settings and Quit and Reopen instead when the missing Screen Recording grant is the likely
    /// cause.
    private func failure(_ message: String) -> some View {
        if model.failureNeedsPermission {
            return MessageCard(symbol: "lock.shield", title: "Screen Recording is off",
                               message: "\(message) \(Self.screenRecordingFix)",
                               actions: [.init("Open System Settings", run: openScreenRecordingSettings), .init("Quit and Reopen", run: Relaunch.now)],
                               overPicture: model.pixelSize != .zero)
        }
        return MessageCard(symbol: model.failureStoppedFromMenuBar ? "pause.circle" : "exclamationmark.triangle",
                           title: "Sharing stopped", message: message, actions: [.init("Retry", run: model.retry)],
                           overPicture: model.pixelSize != .zero)
    }

    private func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
    }
}

/// The strip for the Share screen. Its own view, so only it reads `model.snapshot`, which changes four times a second.
private struct ShareStrip: View {
    let model: ShareModel
    var body: some View {
        TelemetryStrip(snapshot: model.snapshot, resolution: model.resolutionLabel, codec: model.codecLabel,
                       latencyLabel: ShareView.latencyLabel, codecMs: model.codecMs, showsCodec: model.loopback)
    }
}

/// Said over the picture instead of failing silently: a frame that cannot be drawn, a codec setting refused, viewers
/// that cannot reach this Mac. A gold warning glyph, at most 420 pt wide, on the same glass as the panels. When Local
/// Network access is off the notice offers its one fix (spec 9); otherwise it takes no click, so the ink under it still
/// does.
struct Notice: View {
    let text: String
    var body: some View {
        let fixable = LocalNetwork.isOff(text)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(Theme.Colors.gold)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(text).font(.system(size: 12)).foregroundStyle(Theme.Colors.text)
                    .fixedSize(horizontal: false, vertical: true)
                if fixable {
                    Button {
                        NSWorkspace.shared.open(LocalNetwork.settingsURL)
                    } label: {
                        Text("Open System Settings").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.Colors.gold)
                            .contentShape(Rectangle())
                    }
                    // Spec 11: press feedback on every button, as the gold and quiet ones have.
                    .buttonStyle(PressFeedback())
                    .pointerStyle(.link)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: 420, alignment: .leading)
        .glass(in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
        .fixedSize(horizontal: false, vertical: true)
        .allowsHitTesting(fixable)
    }
}

struct PairingPanel: View {
    let name: String, code: String, viewer: String?
    /// The viewer dropped without `bye` and may come back (`ShareModel.viewerReconnecting`).
    var reconnecting = false
    /// `ShareModel.connectionCount`: the gold ring around the viewer's row draws once per viewer that proves the code.
    let connectionCount: Int
    /// `ShareModel.ringShownFor`: the connection the ring last played for, so the panel shown again does not replay it.
    @Binding var ringShownFor: Int
    var body: some View {
        GlassCard {
            VStack(alignment: .trailing, spacing: 0) {
                Text(name).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.Colors.text)
                Text("CODE").font(Theme.Fonts.smallCaps(10)).foregroundStyle(Theme.Colors.secondaryText).tracking(1.2)
                    .padding(.top, 8)
                // Light and large, to read across a desk. Tracking adds its space after the last digit too, so the
                // trailing padding takes it back and the code ends where the name above it ends.
                Text(code).font(Theme.Fonts.code(34)).foregroundStyle(Theme.Colors.gold).tracking(6).padding(.trailing, -6)
                if let viewer {
                    HStack(spacing: 6) {
                        // Inactive while the viewer reconnects; the ring fades with it and draws again once it pairs.
                        Circle().fill(reconnecting ? Theme.Colors.muted : Theme.Colors.success).frame(width: 6, height: 6)
                        Text(viewer).font(.system(size: 11)).foregroundStyle(Theme.Colors.text)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .overlay(ConnectRing(trigger: connectionCount, shownFor: $ringShownFor, reconnecting: reconnecting))
                    .padding(.top, 8)
                    if reconnecting {
                        Text("Reconnecting…").font(.system(size: 11)).foregroundStyle(Theme.Colors.secondaryText).padding(.top, 4)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
    }
}

struct LoopbackPanel: View {
    @Bindable var model: ShareModel
    /// The panel's width while the loop is on: 220 pt, so the slider and the caption do not stretch it over the picture.
    private static let width: CGFloat = 220
    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text("Codec loop").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.Colors.text)
                    if model.loopback { Spacer(minLength: 0) }
                    Toggle("Codec loop", isOn: $model.loopback).labelsHidden().toggleStyle(.switch).tint(Theme.Colors.gold)
                        .controlSize(.small)
                }
                if model.loopback {
                    HStack(alignment: .firstTextBaseline) {
                        Text("QUALITY").font(Theme.Fonts.smallCaps(10)).foregroundStyle(Theme.Colors.secondaryText).tracking(1.2)
                        Spacer(minLength: 8)
                        Text("\(Int(model.qualityMbps)) Mbps").font(Theme.Fonts.figures(11)).foregroundStyle(Theme.Colors.text)
                    }
                    .padding(.top, 4)
                    // Whole Mbps without `step`, which would draw 59 tick marks under the track.
                    Slider(value: Binding(get: { model.qualityMbps },
                                          set: { let v = $0.rounded(); if v != model.qualityMbps { model.qualityMbps = v } }),
                           in: ShareModel.qualityRange)
                        .tint(Theme.Colors.gold).controlSize(.small)
                    // Two lines on purpose: one sentence of 199 pt in a 188 pt column left "the line." alone on the second.
                    Text("Raw left, decoded right.\nDrag the line to compare.").font(.system(size: 11)).foregroundStyle(Theme.Colors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: model.loopback ? Self.width - 32 : nil, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
    }
}

/// The comparison's divider: drag anywhere on the picture to move it. The dot on the line is where people grab it; it
/// grows to 1.3 while dragged. Two capsules beside the dot say which side is which.
struct DividerHandle: View {
    @Binding var position: Double
    /// The right side's label: the codec and the rate, "HEVC · 4 Mbps".
    let decoded: String
    @State private var dragging = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The dot's centre sits this far above the picture's bottom edge (`DividerHandleTests`).
    static let dotInset: CGFloat = 18
    var body: some View {
        GeometryReader { geo in
            let x = geo.size.width * position
            let y = geo.size.height - Self.dotInset
            Color.clear.contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if !dragging { dragging = true }
                        position = min(1, max(0, v.location.x / geo.size.width))
                    }
                    .onEnded { _ in dragging = false })
            // Labels and dot take no click, so a drag that starts on them moves the line like any other.
            Group {
                if x > 64 { label("RAW").frame(width: x - 14, alignment: .trailing).position(x: (x - 14) / 2, y: y) }
                if geo.size.width - x > 150 {
                    label(decoded).frame(width: geo.size.width - x - 14, alignment: .leading)
                        .position(x: x + 14 + (geo.size.width - x - 14) / 2, y: y)
                }
                Circle().fill(Theme.Colors.gold).frame(width: 12, height: 12)
                    .overlay(Circle().strokeBorder(Theme.Colors.background, lineWidth: 2).padding(-2))
                    .scaleEffect(dragging && !reduceMotion ? 1.3 : 1)
                    .animation(Theme.Motion.press, value: dragging)
                    .position(x: x, y: y)
            }
            .allowsHitTesting(false)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased()).font(Theme.Fonts.smallCaps(10)).tracking(1.2).foregroundStyle(Theme.Colors.text)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 8).padding(.vertical, 4)
            .glass(in: Capsule(style: .continuous))
    }
}

/// Quit and Reopen on the Screen Recording card: a Screen Recording grant reaches a running app only once it relaunches,
/// as macOS's own Quit & Reopen says. Opens a new copy of this app, then quits this one once that copy is on its way;
/// if it cannot be opened (a build run outside its bundle), this one stays and the log says why.
@MainActor
enum Relaunch {
    static func now() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            Task { @MainActor in
                if let error {
                    relaunchLog.error("could not reopen Nítido: \(error.localizedDescription, privacy: .public)")
                    return
                }
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

private let relaunchLog = Logger(subsystem: "ai.ronar.nitido", category: "app")
