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

    @ReducedMotion private var reduceMotion

    /// The picture's entrance (spec 11, M6), from the moment the share began capturing: the window grows from its top
    /// left corner over 300 ms while a cover over the picture fades from 40 ms, then the strip (160 ms), the pairing
    /// panel (200 ms), the codec loop panel (240 ms), the code digit by digit (280 ms) and the notices (320 ms).
    enum Stage {
        static let strip: Double = 0.16
        static let pairing: Double = 0.20
        static let loop: Double = 0.24
        static let code: Double = 0.28
        static let notices: Double = 0.32
        /// The strip rises a little further than a row: it comes up with the window's bottom edge.
        static let stripRise: CGFloat = 8
    }

    /// The body reads no figure: the strip is its own view (`ShareStrip`), so the snapshot four times a second
    /// re-evaluates the strip alone, not the panels, the notices and the picture.
    public var body: some View {
        let area = areaSize
        let since = model.capturingSince
        let failed: Bool = if case .failed = model.state { true } else { false }
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                // The picture, and what lies exactly over it: the ink, and the divider handle, whose drags map to it.
                // Laid out at its final size from the first frame; no animation ever reaches its frame, so its
                // drawable is sized once per picture size (spec 11).
                ZStack(alignment: .topLeading) {
                    VideoSurface(sink: model.sink).frame(width: pointSize.width, height: pointSize.height)
                        .transaction { $0.animation = nil }
                        .accessibilityElement()
                        .accessibilityLabel("The picture you are sharing")
                        .accessibilityAddTraits(.isImage)
                    // Above the video, below the divider handle: while the codec loop is on the handle takes the
                    // drags, so the ink is drawn with the loop off.
                    InkOverlay(controller: model.ink).frame(width: pointSize.width, height: pointSize.height)
                        .transaction { $0.animation = nil }
                    // Covers the whole picture, so it sits below everything that takes a click: the failure's buttons
                    // and both panels.
                    if model.loopback {
                        DividerHandle(position: $model.dividerPosition, decoded: "\(model.codecLabel == "raw" ? "HEVC" : model.codecLabel) · \(Int(model.qualityMbps)) Mbps",
                                      since: model.loopToggledAt)
                            .frame(width: pointSize.width, height: pointSize.height)
                            .exitTransition(reduceMotion: reduceMotion)
                    }
                }
                .frame(width: pointSize.width, height: pointSize.height, alignment: .topLeading)
                .padding(.leading, pictureOrigin.x).padding(.top, pictureOrigin.y)
                // The picture fades in by a cover of the background colour, never by its own opacity or a scale.
                if model.pixelSize != .zero {
                    PictureCover(since: since)
                        .frame(width: pointSize.width, height: pointSize.height)
                        .padding(.leading, pictureOrigin.x).padding(.top, pictureOrigin.y)
                        .id(since)
                }
                // The rest keeps to the picture area, which a small picture leaves larger than itself.
                if model.state == .picking {
                    MessageCard(symbol: "rectangle.dashed", title: "Choose what to share",
                                message: "Pick a window or a display in the system picker.", note: screenRecordingNote,
                                overPicture: model.pixelSize != .zero)
                        .entrance(.compact, delay: Self.cardDelay)
                        .frame(width: area.width, height: area.height)
                        .exitTransition(outScale: Theme.Motion.screenScale, reduceMotion: reduceMotion)
                }
                // The last picture stays, dimmed, so it does not read as still live (as the viewer's reconnect).
                Theme.Colors.background.opacity(failed ? Theme.Motion.failureDim : 0)
                    .frame(width: area.width, height: area.height)
                    .allowsHitTesting(false)
                    .animation((failed ? MessageMotion.dimIn : MessageMotion.dimOut).animation, value: failed)
                if case .failed(let message) = model.state {
                    failure(message)
                        .entrance(.compact, delay: MessageMotion.cardDelay)
                        .frame(width: area.width, height: area.height)
                        .exitTransition(outScale: Theme.Motion.screenScale, reduceMotion: reduceMotion)
                }
                if model.state == .capturing {
                    NoticeStack(texts: notices, since: since, stageDelay: Stage.notices)
                        .padding(Self.inset)
                        .frame(width: area.width, height: area.height, alignment: .bottomLeading)
                }
                // Only over a live share: while picking, or after a failure (the listener is stopped until Retry),
                // the code would send a viewer looking for a Mac it cannot find, and the switch would do nothing.
                if model.showsLiveControls {
                    // The name viewers see in their list ("Mac (2)" when another Mac has this one); the key stays
                    // derived from `name`, which the TXT record publishes.
                    PairingPanel(name: model.advertisedName ?? model.name, code: model.code, viewer: model.viewerName,
                                 reconnecting: model.viewerReconnecting, connectionCount: model.connectionCount,
                                 ringShownFor: $model.ringShownFor, since: since, viewerSince: model.viewerSince)
                        .entrance(.scale(Theme.Motion.enterScale, anchor: .topTrailing), delay: Stage.pairing, since: since)
                        .padding(Self.inset)
                        .frame(width: area.width, height: area.height, alignment: .topTrailing)
                        .exitTransition(reduceMotion: reduceMotion)
                    LoopbackPanel(model: model)
                        .entrance(.scale(Theme.Motion.enterScale, anchor: .topLeading), delay: Stage.loop, since: since)
                        .padding(Self.inset)
                        .frame(width: area.width, height: area.height, alignment: .topLeading)
                        .exitTransition(reduceMotion: reduceMotion)
                }
            }
            // The picture area, whatever an overlay asks for.
            .frame(width: area.width, height: area.height, alignment: .topLeading)
            // Only while capturing: while picking, or after a failure, it would show a row of "·" or stale figures.
            // It rises with the window's bottom edge as the picture arrives; ⌘H shows and hides it at once.
            if model.showTelemetry && model.state == .capturing {
                ShareStrip(model: model)
                    .entrance(.rise(Stage.stripRise), delay: Stage.strip, since: since)
            }
        }
        // As wide as the picture area (the picture to the whole point, or the minimum), so
        // `.windowResizability(.contentSize)` fixes the window's width to every pick, narrower ones included, the
        // way it fixes the height; the strip wraps instead of widening it. The window follows it with the window
        // curve (`AnimatedArea`, `RootView`).
        .frame(width: area.width)
        .background(Theme.Colors.background)
    }

    /// The picture area the window is sized to for `model` (`RootView`'s `AnimatedArea`).
    static func area(for model: ShareModel) -> CGSize { Fit.area(for: model.fittedPointSize) }

    /// The picker's card comes in 40 ms after the screen it is on (spec 11, M3): Welcome's card has receded by then.
    static let cardDelay: Double = 0.04

    /// What the notices say now, in order.
    private var notices: [String] {
        var texts: [String] = []
        if let reason = model.renderFailure { texts.append("The picture cannot be drawn: \(reason)") }
        if let text = model.codecNotice { texts.append(text) }
        if let text = model.networkNotice { texts.append(text) }
        if let text = model.viewerNotice { texts.append(text) }
        return texts
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
        TelemetryStrip(snapshot: model.stripSnapshot, resolution: model.resolutionLabel, codec: model.codecLabel,
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

/// The notices over the picture, bottom left (spec 11, M16). Each rises 6 pt as it comes, several at once 40 ms apart;
/// the ones there as the picture arrives follow its entrance (`stageDelay` after `since`). One goes over 120 ms, and only
/// once it has been up a second, so a single frame that could not be drawn does not flash a notice: it is shown, then
/// held, never hidden at once. The ones left close the gap over 240 ms.
struct NoticeStack: View {
    let texts: [String]
    let since: CFTimeInterval?
    let stageDelay: Double
    @ReducedMotion private var reduceMotion
    @State private var shown: [Shown] = []
    /// What the model says now, for a hold that ends after `texts` last changed.
    @State private var said: [String] = []

    struct Shown: Equatable, Identifiable {
        let text: String
        /// When it was first shown (`CACurrentMediaTime`).
        let at: CFTimeInterval
        let delay: Double
        var id: String { text }
    }

    /// A notice stays at least this long once shown.
    nonisolated static let minimumShown: Double = 1.0

    /// The notices shown after `said` changes at `now`: the ones still said, and the ones no longer said that have not
    /// been up `minimumShown` yet, in place; then the new ones, in the model's order, each 40 ms after the one before it
    /// in this batch, or after the picture's entrance while it is under way.
    nonisolated static func reconcile(_ shown: [Shown], said: [String], now: CFTimeInterval, since: CFTimeInterval?,
                                      stageDelay: Double) -> [Shown] {
        var next = shown.filter { said.contains($0.text) || now - $0.at < minimumShown }
        let inStage = since.map { now - $0 < stageDelay + Entrance.grace } ?? false
        let base = inStage ? max(0, stageDelay - (now - (since ?? now))) : 0
        var batch = 0
        for text in said where !next.contains(where: { $0.text == text }) {
            next.append(Shown(text: text, at: now, delay: base + Double(batch) * Theme.Motion.stagger))
            batch += 1
        }
        return next
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(shown) { item in
                Notice(text: item.text)
                    .entrance(.row, delay: item.delay, since: item.at)
                    .exitTransition(reduceMotion: reduceMotion)
            }
        }
        .animation(reduceMotion ? nil : Theme.Motion.move.animation, value: shown.map(\.text))
        .onChange(of: texts, initial: true) { _, new in
            said = new
            update()
        }
    }

    private func update() {
        let now = CACurrentMediaTime()
        shown = Self.reconcile(shown, said: said, now: now, since: since, stageDelay: stageDelay)
        // A notice held past what the model says goes once its second is up.
        if let due = shown.filter({ !said.contains($0.text) }).map({ $0.at + Self.minimumShown }).min() {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(max(0, due - CACurrentMediaTime()) + 0.01))
                update()
            }
        }
    }
}

/// The sharer's panel: its name, the code, and the viewer once one pairs (spec 11, M8 to M10). The code types itself in
/// with the picture's entrance; a viewer that connects grows the panel below the code (which stays exactly where it is)
/// and fills its row: the row, the name, the dot on a spring, then the ring. While the viewer reconnects its dot turns
/// gold and breathes and the panel says so; a viewer that leaves takes its row with it.
struct PairingPanel: View {
    let name: String, code: String, viewer: String?
    /// The viewer dropped without `bye` and may come back (`ShareModel.viewerReconnecting`).
    var reconnecting = false
    /// `ShareModel.connectionCount`: the gold ring around the viewer's row draws once per viewer that proves the code.
    let connectionCount: Int
    /// `ShareModel.ringShownFor`: the connection the ring last played for, so the panel shown again does not replay it.
    @Binding var ringShownFor: Int
    /// The picture's stage (`ShareModel.capturingSince`), which the code's reveal follows.
    var since: CFTimeInterval? = nil
    /// When the viewer proved the code (`ShareModel.viewerSince`), which its row's entrance follows.
    var viewerSince: CFTimeInterval? = nil
    @ReducedMotion private var reduceMotion

    /// A viewer connecting (M9), from the moment it proved the code.
    enum Connect {
        static let row: Double = 0.06
        static let name: Double = 0.10
        static let dot: Double = 0.12
        static let ring: Double = 0.16
        /// The ring drawing again around a row that stayed (a reconnect that came back).
        static let ringAgain: Double = 0.08
        /// The panel folding back once a row or a line goes.
        static let shrink = Theme.Motion.move.over(0.2)
    }

    /// Whether the viewer's row and the reconnecting line are in the panel: set inside an explicit transaction as the
    /// model changes, so the panel grows and folds on its own curve (an implicit animation left the Liquid Glass to snap
    /// a frame or more late, recorded 2026-10-12). The row's name is kept while the row goes.
    @State private var rowShown: Bool
    @State private var lineShown: Bool
    @State private var rowName: String?

    init(name: String, code: String, viewer: String?, reconnecting: Bool = false, connectionCount: Int, ringShownFor: Binding<Int>,
         since: CFTimeInterval? = nil, viewerSince: CFTimeInterval? = nil) {
        self.name = name; self.code = code; self.viewer = viewer; self.reconnecting = reconnecting
        self.connectionCount = connectionCount; _ringShownFor = ringShownFor; self.since = since; self.viewerSince = viewerSince
        _rowShown = State(initialValue: viewer != nil)
        _lineShown = State(initialValue: viewer != nil && reconnecting)
        _rowName = State(initialValue: viewer)
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .trailing, spacing: 0) {
                Text(name).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.Colors.text)
                Text("CODE").font(Theme.Fonts.smallCaps(10)).foregroundStyle(Theme.Colors.secondaryText).tracking(1.2)
                    .padding(.top, 8)
                // Light and large, to read across a desk. Tracking adds its space after the last digit too, so the
                // trailing padding takes it back and the code ends where the name above it ends.
                TypedCode(code: code, delay: ShareView.Stage.code - ShareView.Stage.pairing,
                          since: since.map { $0 + ShareView.Stage.pairing })
                    .padding(.trailing, -6)
                if rowShown, let viewer = viewer ?? rowName {
                    VStack(alignment: .trailing, spacing: 0) {
                        HStack(spacing: 6) {
                            // Gold and breathing while the viewer reconnects; the ring fades with it and draws again once
                            // it pairs.
                            PulseDot(color: reconnecting ? Theme.CanvasColors.gold : NSColor(hex: Theme.Hex.success), breathing: reconnecting)
                                .frame(width: 6, height: 6)
                                .entrance(.scale(0.5), delay: Connect.dot, spring: Theme.Motion.alive, since: viewerSince)
                            Text(viewer).font(.system(size: 11)).foregroundStyle(Theme.Colors.text)
                                .entrance(.slide(Theme.Motion.rise), delay: Connect.name, since: viewerSince)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .overlay(ConnectRing(trigger: connectionCount, shownFor: $ringShownFor, reconnecting: reconnecting,
                                             delay: connectionCount <= 1 ? Connect.ring : Connect.ringAgain))
                        .entrance(.scale(Theme.Motion.enterScale, anchor: .trailing), delay: Connect.row, since: viewerSince)
                        .padding(.top, 8)
                        if lineShown {
                            Text("Reconnecting…").font(.system(size: 11)).foregroundStyle(Theme.Colors.secondaryText).padding(.top, 4)
                                .entrance(.rise(4), delay: 0.06, curve: Theme.Motion.enter.over(0.2))
                                .exitTransition(reduceMotion: reduceMotion)
                        }
                    }
                    .exitTransition(reduceMotion: reduceMotion)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .onChange(of: viewer) { _, new in
            if let new { rowName = new }
            change(grows: new != nil) { rowShown = new != nil; if new == nil { lineShown = false } }
        }
        .onChange(of: reconnecting) { _, now in change(grows: now) { lineShown = now && viewer != nil } }
    }

    /// The panel grows below the code as a row or a line comes (240 ms) and folds back as it goes (200 ms); at once under
    /// Reduce Motion.
    private func change(grows: Bool, _ body: () -> Void) {
        guard !reduceMotion else { body(); return }
        withAnimation((grows ? Theme.Motion.move : Connect.shrink).animation) { body() }
    }
}

struct LoopbackPanel: View {
    @Bindable var model: ShareModel
    @ReducedMotion private var reduceMotion
    /// The panel's width while the loop is on: 220 pt, so the slider and the caption do not stretch it over the picture.
    private static let width: CGFloat = 220

    /// The loop turned on by the pointer (spec 11, M12): the panel unfolds over 240 ms, then the quality row, the slider
    /// and the caption rise in 40 ms apart from 80 ms; off, they go over 100 ms and the panel folds over 200 ms.
    enum Unfold {
        static let rows: Double = 0.08
        static let row = Theme.Motion.enter.over(0.2)
        static let rowsOut = Theme.Motion.exit.over(0.1)
        static let fold = Theme.Motion.move.over(0.2)
    }

    var body: some View {
        let since = model.loopToggledAt
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text("Codec loop").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.Colors.text)
                    if model.loopback { Spacer(minLength: 0) }
                    Toggle("Codec loop", isOn: pointerToggle).labelsHidden().toggleStyle(.switch).tint(Theme.Colors.gold)
                        .controlSize(.small)
                }
                if model.loopback {
                    HStack(alignment: .firstTextBaseline) {
                        Text("QUALITY").font(Theme.Fonts.smallCaps(10)).foregroundStyle(Theme.Colors.secondaryText).tracking(1.2)
                        Spacer(minLength: 8)
                        // SF Mono, so the label's width never moves as it rolls.
                        Text("\(Int(model.qualityMbps)) Mbps").font(Theme.Fonts.figures(11)).foregroundStyle(Theme.Colors.text)
                            .contentTransition(reduceMotion ? .opacity : .numericText(value: model.qualityMbps))
                            .animation((reduceMotion ? TelemetryMotion.reducedRoll : Theme.Motion.figure).animation, value: model.qualityMbps)
                    }
                    .padding(.top, 4)
                    .entrance(.rise(4), delay: Unfold.rows, curve: Unfold.row, since: since, enabled: since != nil)
                    .exitTransition(exit: Unfold.rowsOut, reduceMotion: reduceMotion)
                    // Whole Mbps without `step`, which would draw 59 tick marks under the track.
                    Slider(value: Binding(get: { model.qualityMbps },
                                          set: { let v = $0.rounded(); if v != model.qualityMbps { arrive(at: v); model.qualityMbps = v } }),
                           in: ShareModel.qualityRange)
                        .tint(Theme.Colors.gold).controlSize(.small)
                        .entrance(.rise(4), delay: Unfold.rows + Theme.Motion.stagger, curve: Unfold.row, since: since, enabled: since != nil)
                        .exitTransition(exit: Unfold.rowsOut, reduceMotion: reduceMotion)
                    // Two lines on purpose: one sentence of 199 pt in a 188 pt column left "the line." alone on the second.
                    Text("Raw left, decoded right.\nDrag the line to compare.").font(.system(size: 11)).foregroundStyle(Theme.Colors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .entrance(.rise(4), delay: Unfold.rows + 2 * Theme.Motion.stagger, curve: Unfold.row, since: since, enabled: since != nil)
                        .exitTransition(exit: Unfold.rowsOut, reduceMotion: reduceMotion)
                }
            }
            .frame(width: model.loopback ? Self.width - 32 : nil, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
    }

    /// The slider reaching an end (2 or 60 Mbps) taps the trackpad once (spec 11, M14), so the hand feels where the range
    /// stops; a step within the range does not.
    private func arrive(at value: Double) {
        guard Self.reachesAnEnd(from: model.qualityMbps, to: value) else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    nonisolated static func reachesAnEnd(from old: Double, to new: Double) -> Bool {
        new != old && (new == ShareModel.qualityRange.lowerBound || new == ShareModel.qualityRange.upperBound)
    }

    /// The switch flipped by the pointer: inside an explicit transaction, so the panel unfolds (and the strip makes room
    /// for its codec figure) on the move curve, and what the loop brings stages from now (`ShareModel.loopToggledAt`).
    /// Under Reduce Motion the panel takes its size at once and its rows fade. ⌘L comes through `AppModel` instead, at
    /// once.
    private var pointerToggle: Binding<Bool> {
        Binding(get: { model.loopback }, set: { on in
            guard on != model.loopback else { return }
            model.loopToggledAt = CACurrentMediaTime()
            guard !reduceMotion else { model.loopback = on; return }
            withAnimation((on ? Theme.Motion.move : Unfold.fold).animation) { model.loopback = on }
        })
    }
}

/// The comparison's divider (spec 11, M12, M13): a measuring instrument, so the line is where the cut is, always. Drag
/// anywhere on the picture to move it: the cut and the line follow the pointer 1:1, and the dot on the line, where people
/// grab it, grows to 1.3 on a spring while held (1.12 when the pointer comes within 20 pt). Two capsules beside the dot
/// say which side is which; one near an edge fades toward the dot rather than popping, with 8 pt of hysteresis so a drag
/// resting on the threshold does not flicker. Turned on by the pointer, the dot comes in from 0.8 and the labels slide
/// in away from it.
struct DividerHandle: View {
    @Binding var position: Double
    /// The right side's label: the codec and the rate, "HEVC · 4 Mbps".
    let decoded: String
    /// When the loop was switched on by the pointer (`ShareModel.loopToggledAt`); nil shows everything at once.
    var since: CFTimeInterval? = nil
    @State private var dragging = false
    @State private var near = false
    @State private var rawShown = true
    @State private var decodedShown = true
    @ReducedMotion private var reduceMotion
    /// The dot's centre sits this far above the picture's bottom edge (`DividerHandleTests`).
    static let dotInset: CGFloat = 18

    /// Where a label stops fitting beside the dot: RAW under 64 pt from the left edge, the decoded label under 150 pt
    /// from the right; it comes back 8 pt further out.
    nonisolated static let rawRoom: CGFloat = 64
    nonisolated static let decodedRoom: CGFloat = 150
    nonisolated static let labelHysteresis: CGFloat = 8
    /// The pointer within this many points of the dot lifts it.
    nonisolated static let nearDot: CGFloat = 20

    /// Whether a label shows with `room` points beside the dot, given whether it shows now.
    nonisolated static func shows(_ showing: Bool, room: CGFloat, needs: CGFloat) -> Bool {
        showing ? room > needs : room >= needs + labelHysteresis
    }

    /// A label's way in near an edge, and the dot's, and the labels' slide when the loop comes on.
    enum Labels {
        static let back = Theme.Motion.enter.over(0.18)
        static let dot = Theme.Motion.enter.over(0.2)
        static let raw: Double = 0.20
        static let decoded: Double = 0.24
    }

    var body: some View {
        GeometryReader { geo in
            let x = geo.size.width * position
            let y = geo.size.height - Self.dotInset
            Color.clear.contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if !dragging { withAnimation(Theme.Motion.grab.animation) { dragging = true } }
                        position = min(1, max(0, v.location.x / geo.size.width))
                    }
                    .onEnded { _ in withAnimation(Theme.Motion.letGo.animation) { dragging = false } })
                .onContinuousHover(coordinateSpace: .local) { phase in
                    let close: Bool = if case .active(let p) = phase { hypot(p.x - x, p.y - y) <= Self.nearDot } else { false }
                    if close != near { withAnimation(Theme.Motion.hover.animation) { near = close } }
                }
                // Drag anywhere moves the line, and the pointer says so.
                .pointerStyle(.columnResize)
            // Labels and dot take no click, so a drag that starts on them moves the line like any other.
            Group {
                if rawShown {
                    label("RAW").frame(width: max(0, x - 14), alignment: .trailing).position(x: (x - 14) / 2, y: y)
                        .entrance(.slide(Theme.Motion.rise), delay: Labels.raw, curve: Labels.dot, since: since, enabled: since != nil)
                        .presence(.scale(Theme.Motion.enterScale, anchor: .trailing), outScale: Theme.Motion.enterScale,
                                  enter: Labels.back, reduceMotion: reduceMotion)
                }
                if decodedShown {
                    label(decoded).frame(width: max(0, geo.size.width - x - 14), alignment: .leading)
                        .position(x: x + 14 + (geo.size.width - x - 14) / 2, y: y)
                        .entrance(.slide(-Theme.Motion.rise), delay: Labels.decoded, curve: Labels.dot, since: since, enabled: since != nil)
                        .presence(.scale(Theme.Motion.enterScale, anchor: .leading), outScale: Theme.Motion.enterScale,
                                  enter: Labels.back, reduceMotion: reduceMotion)
                }
                // Turned on by the pointer: a light runs up the line from its handle as the comparison opens.
                if let since, !reduceMotion, CACurrentMediaTime() - since < DividerGlint.end {
                    DividerGlint(since: since, rise: y).position(x: x, y: y / 2)
                }
                Circle().fill(Theme.Colors.gold).frame(width: 12, height: 12)
                    .overlay(Circle().strokeBorder(Theme.Colors.background, lineWidth: 2).padding(-2))
                    .scaleEffect(reduceMotion ? 1 : dragging ? 1.3 : near ? 1.12 : 1)
                    .entrance(.scale(0.8), curve: Labels.dot, since: since, enabled: since != nil)
                    .position(x: x, y: y)
            }
            .allowsHitTesting(false)
            .onChange(of: x, initial: true) { _, x in
                let raw = Self.shows(rawShown, room: x, needs: Self.rawRoom)
                let dec = Self.shows(decodedShown, room: geo.size.width - x, needs: Self.decodedRoom)
                if raw != rawShown { rawShown = raw }
                if dec != decodedShown { decodedShown = dec }
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased()).font(Theme.Fonts.smallCaps(10)).tracking(1.2).foregroundStyle(Theme.Colors.text)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 8).padding(.vertical, 4)
            .glass(in: Capsule(style: .continuous))
    }
}

/// The codec loop switched on by the pointer (spec 11, M12, amended 2026-10-12): a light runs up the divider line from
/// its handle to the top of the picture over 220 ms on the strong ease-in-out, 40 ms after the switch, then fades. The
/// line itself is the frame's, drawn exactly on the cut from the first comparison frame: the choreography's reveal hid it
/// for 260 ms through a flag on the frame path and a hand-off back to it, and the glint gives the same sense of the line
/// drawing itself up without touching the frame path. A narrow band of the gold highlight, nearly white at its core,
/// added over the line (`.plusLighter`), taking no click.
struct DividerGlint: View {
    let since: CFTimeInterval
    /// How far it rises: from the handle's centre to the top of the picture, in points.
    let rise: CGFloat
    @State private var risen = false
    @State private var faded = false

    nonisolated static let delay: Double = 0.04
    nonisolated static let fade = Theme.Motion.exit
    nonisolated static var end: Double { delay + Theme.Motion.reveal.duration + fade.duration }
    static let length: CGFloat = 90

    var body: some View {
        LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: Theme.Colors.goldHighlight.opacity(0.6), location: 0.3),
            .init(color: Color(hex: 0xfff4d6).opacity(0.95), location: 0.5),
            .init(color: Theme.Colors.goldHighlight.opacity(0.6), location: 0.7),
            .init(color: .clear, location: 1),
        ], startPoint: .top, endPoint: .bottom)
        .frame(width: 2, height: Self.length)
        .offset(y: risen ? -rise / 2 : rise / 2)
        .opacity(faded ? 0 : 1)
        .blendMode(.plusLighter)
        .frame(width: 2, height: rise)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            let wait = Entrance.remainingDelay(Self.delay, since: since, now: CACurrentMediaTime())
            withAnimation(Theme.Motion.reveal.animation(after: wait)) { risen = true } completion: {
                withAnimation(Self.fade.animation) { faded = true }
            }
        }
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
