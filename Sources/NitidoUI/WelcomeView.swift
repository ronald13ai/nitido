import SwiftUI
import AppKit

/// The first screen: one solid card on the maison black, with a faint gold warmth behind it. Glass over flat black
/// bends nothing (it showed as a faint rim when the window was key and a grey slab when it was not), so the card is the
/// surface with a hairline and a highlight along its top edge. On the 8 pt grid: wordmark, 8, subtitle, 24, buttons,
/// 32, credit, inside 48 by 40.
///
/// At launch (spec 11, M1) the first second says "maison": the warmth rises, the card settles, the name comes into
/// focus, the rest follows 40 ms apart, then one glint of gold crosses the wordmark. It starts when the window is first
/// on screen (`WindowVisibility`), plays once per process (`AppModel.launchPlayed`), and Share and View take a click from
/// the first frame. Coming back to Welcome the card returns with the screen, nothing staged.
public struct WelcomeView: View {
    /// How Welcome arrives: staged at launch, or as it is on a return.
    public enum Arrival: Equatable, Sendable { case launch, `return` }

    /// Welcome's canvas, which every screen without a picture shares.
    static let size = CGSize(width: 600, height: 400)

    let entrance: Arrival
    let onShare: () -> Void
    let onView: () -> Void
    let onLaunch: () -> Void
    @ReducedMotion private var reduceMotion
    /// The launch's t = 0 has come: the window is on screen. At once on a return.
    @State private var started: Bool

    public init(entrance: Arrival = .return, onShare: @escaping () -> Void, onView: @escaping () -> Void,
                onLaunch: @escaping () -> Void = {}) {
        self.entrance = entrance; self.onShare = onShare; self.onView = onView; self.onLaunch = onLaunch
        _started = State(initialValue: entrance != .launch)
    }

    public var body: some View {
        let launching = entrance == .launch
        ZStack {
            // Under the transparent title bar too, so the black and its warmth run to the window's edges.
            Theme.Colors.background.ignoresSafeArea()
            if started {
                RadialGradient(colors: [Theme.Colors.gold.opacity(0.07), .clear], center: .center, startRadius: 0, endRadius: 340)
                    .ignoresSafeArea()
                    .entrance(.fade, curve: LaunchChoreography.warmth, enabled: launching)
                VStack(spacing: 0) {
                    wordmark
                        .overlay {
                            if LaunchChoreography.playsShimmer(entrance, reduceMotion: reduceMotion) {
                                WordmarkShimmer { wordmark }
                            }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Nítido")
                        .entrance(.focus(Theme.Motion.focusBlur), delay: LaunchChoreography.wordmark, curve: Theme.Motion.focus,
                                  enabled: launching)
                    Text("Share a screen to another Mac. Crisp text, measured latency, ink on top.")
                        .font(.system(size: 13)).foregroundStyle(Theme.Colors.secondaryText)
                        .padding(.top, 8)
                        .entrance(.row, delay: LaunchChoreography.subtitle, enabled: launching)
                    HStack(spacing: 12) {
                        GoldButton("Share", action: onShare)
                        QuietButton("View", action: onView)
                    }
                    .padding(.top, 24)
                    .entrance(.compact, delay: LaunchChoreography.buttons, enabled: launching)
                    Text("BY RONALD RODRÍGUEZ · RONAR AI").font(Theme.Fonts.smallCaps(10)).foregroundStyle(Theme.Colors.gold).tracking(2)
                        .padding(.top, 32)
                        .entrance(.row, delay: LaunchChoreography.byline, enabled: launching)
                }
                .padding(.horizontal, 48).padding(.vertical, 40)
                // The card's surface settles on its own, so its hairline and highlight arrive with it, never apart, and
                // the content's own entrances do not multiply with the card's fade.
                .background {
                    SolidCardSurface().entrance(.scale(Theme.Motion.screenScale), enabled: launching)
                }
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background {
            if launching && !started { WindowVisibility { begin() } }
        }
        .onAppear {
            guard launching, !started else { return }
            // Drawn where no window will ever report (an offscreen render): the content shows after a while anyway.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(LaunchChoreography.noWindowFallback))
                begin()
            }
        }
    }

    private var wordmark: some View {
        // At 56 pt the í's acute nearly touches the N's top serif ("Ńtido" at a glance): 2.5 pt between them.
        Text("\(Text("N").kerning(2.5))ítido").font(Theme.Fonts.wordmark(56)).foregroundStyle(Theme.Colors.cream)
    }

    private func begin() {
        guard !started else { return }
        started = true
        onLaunch()
    }
}

/// The launch's timeline (spec 11, M1), from the moment the window is first on screen.
enum LaunchChoreography {
    /// The gold warmth rises over 480 ms.
    static let warmth = Theme.Motion.enter.over(0.48)
    static let wordmark: Double = 0.06
    static let subtitle: Double = 0.10
    static let buttons: Double = 0.14
    static let byline: Double = 0.18
    /// Should the window's notifications miss the moment, the launch starts this long after the view is in a window that
    /// is ordered in (`WindowVisibility`).
    static let visibilityFallback: Double = 0.15
    /// With no window at all, the content shows after this long.
    static let noWindowFallback: Double = 1.5

    /// The glint plays at launch only (once per process), never under Reduce Motion.
    static func playsShimmer(_ entrance: WelcomeView.Arrival, reduceMotion: Bool) -> Bool {
        entrance == .launch && !reduceMotion
    }

    /// How Welcome arrives: the launch the first time in this process, a return after that.
    static func arrival(launchPlayed: Bool) -> WelcomeView.Arrival { launchPlayed ? .return : .launch }
}

/// The one gold glint across the wordmark at launch (spec 11, M1): a band 36 pt wide (about 28 % of the wordmark),
/// skewed 20°, masked by the wordmark's own glyphs and added over them (`.plusLighter`), gold at its edges and nearly
/// white at its core, so over the cream it reads as a warm glint passing through the letters. It travels from just left
/// of the wordmark to just past its right edge over 760 ms on the system ease-in-out, 440 ms after the launch began:
/// on the letters from about 670 to 1080 ms (`Theme.Motion.shimmer`).
struct WordmarkShimmer<Glyphs: View>: View {
    let glyphs: Glyphs
    @State private var across = false
    init(@ViewBuilder glyphs: () -> Glyphs) { self.glyphs = glyphs() }

    nonisolated static var band: CGFloat { 36 }
    nonisolated static var skew: Double { 20 * .pi / 180 }

    /// The band's leading edge, before and after its pass, for a wordmark `width` wide and `height` tall: fully clear of
    /// the glyphs at both ends, the skew's lean included.
    nonisolated static func travel(width: CGFloat, height: CGFloat) -> (from: CGFloat, to: CGFloat) {
        let lean = height * CGFloat(tan(skew)) / 2
        return (-band - lean, width + lean)
    }

    var body: some View {
        GeometryReader { geo in
            let path = Self.travel(width: geo.size.width, height: geo.size.height)
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: Theme.Colors.goldHighlight.opacity(0.35), location: 0.35),
                .init(color: Color(hex: 0xfff4d6).opacity(0.5), location: 0.5),
                .init(color: Theme.Colors.goldHighlight.opacity(0.35), location: 0.65),
                .init(color: .clear, location: 1),
            ], startPoint: .leading, endPoint: .trailing)
            .frame(width: Self.band, height: geo.size.height)
            .transformEffect(CGAffineTransform(a: 1, b: 0, c: -CGFloat(tan(Self.skew)), d: 1,
                                               tx: geo.size.height * CGFloat(tan(Self.skew)) / 2, ty: 0))
            .offset(x: across ? path.to : path.from)
        }
        .mask { glyphs }
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            withAnimation(Theme.Motion.shimmer.animation(after: Theme.Motion.shimmerDelay)) { across = true }
        }
    }
}

/// Calls `visible` once, when the window holding it is first on screen: key, or visible to the person (its occlusion
/// state), or, should both notifications miss the moment, ordered in 150 ms after it was first checked. `onAppear` can
/// come before the window is ordered in, and an entrance would then play unseen.
struct WindowVisibility: NSViewRepresentable {
    let visible: @MainActor () -> Void
    func makeNSView(context: Context) -> WindowVisibilityView { WindowVisibilityView(visible: visible) }
    func updateNSView(_ view: WindowVisibilityView, context: Context) { view.visible = visible }
}

final class WindowVisibilityView: NSView {
    var visible: (@MainActor () -> Void)?
    private var fired = false

    init(visible: @escaping @MainActor () -> Void) { self.visible = visible; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification, NSWindow.didUpdateNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowChanged(_:)), name: name, object: window)
        }
        check()
    }

    @objc private func windowChanged(_ note: Notification) { check() }

    private func check() {
        guard !fired, let window, window.isVisible else { return }
        if window.isKeyWindow || window.occlusionState.contains(.visible) { fire(); return }
        if fallback == nil {
            fallback = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(LaunchChoreography.visibilityFallback))
                guard let self, !Task.isCancelled, self.window?.isVisible == true else { return }
                self.fire()
            }
        }
    }

    private var fallback: Task<Void, Never>?

    private func fire() {
        guard !fired else { return }
        fired = true
        fallback?.cancel()
        NotificationCenter.default.removeObserver(self)
        // After this update: the window is on screen, and the entrance it starts is seen from its first frame.
        DispatchQueue.main.async { [visible] in visible?() }
    }
}
