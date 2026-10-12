import SwiftUI
import QuartzCore

// The motion primitives every screen shares (spec 11, values in `Theme.Motion`): the Reduce Motion policy, staged
// entrances, the screen transitions and their direction, the frame that sizes the window, and the instant path the
// keyboard takes.

/// Whether motion is reduced: the system's Reduce Motion, unless something above says otherwise. The recording harness
/// renders both variants this way, without touching System Settings.
public struct MotionPolicy: Equatable, Sendable {
    /// Nil: the system's setting.
    public var reduceMotion: Bool?
    /// False: the strip's figures and the codec loop's quality change at once, without their roll or crossfade. Only
    /// the README's reel sets it: its GIF, at 15 fps, caught a 180 ms roll halfway, two glyphs in one place. The app
    /// never does.
    public var rollsFigures: Bool
    public init(reduceMotion: Bool? = nil, rollsFigures: Bool = true) { self.reduceMotion = reduceMotion; self.rollsFigures = rollsFigures }
    public func resolved(system: Bool) -> Bool { reduceMotion ?? system }
}

extension EnvironmentValues {
    @Entry public var motionPolicy = MotionPolicy()
}

/// Reduce Motion as the views read it: the policy's answer, else the system's.
@MainActor @propertyWrapper
struct ReducedMotion: DynamicProperty {
    @Environment(\.accessibilityReduceMotion) private var system
    @Environment(\.motionPolicy) private var policy
    var wrappedValue: Bool { policy.resolved(system: system) }
}

extension EnvironmentValues {
    /// Reduce Motion for an AppKit view under SwiftUI (`NSViewRepresentable.updateNSView`), by the same rule.
    var reducesMotion: Bool { motionPolicy.resolved(system: accessibilityReduceMotion) }
}

@MainActor
enum Instantly {
    /// Runs `change` with every animation it would start turned off, its transitions and the window's size included:
    /// the path every keyboard action takes (⌘H, ⌘L, ⌘Z, ⌘⌫, Esc), since an action repeated often never animates.
    static func run(_ change: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, change)
    }
}

// MARK: Entrances

/// How an element enters: from opacity 0, with a scale (compact things), a rise or a slide (wide things, text), or a
/// blur (the wordmark coming into focus). Never from scale 0.
public enum EntranceMotion: Equatable, Sendable {
    case fade
    case scale(CGFloat, anchor: UnitPoint = .center)
    /// From this many points below (positive) or above (negative).
    case rise(CGFloat)
    /// From this many points to the right (positive) or left (negative).
    case slide(CGFloat)
    case focus(CGFloat)

    static let compact = EntranceMotion.scale(Theme.Motion.enterScale)
    static let row = EntranceMotion.rise(Theme.Motion.rise)

    /// What remains under Reduce Motion: the fade, and the focus pull, which moves nothing.
    func reduced(_ reduceMotion: Bool) -> EntranceMotion {
        guard reduceMotion else { return self }
        if case .focus = self { return self }
        return .fade
    }
}

/// One element of a staged entrance: in from `motion`, `delay` after its stage began, on `curve`. `since` is when the
/// stage began (a picture's first frame, a connection): an element inserted after its slot has passed (the strip shown
/// again with ⌘H a minute later, a panel on a screen shown again) is simply there, since an entrance plays once, with
/// its stage. `enabled` false puts it there at once (a screen that comes back, a keyboard path).
struct Entrance: ViewModifier {
    let motion: EntranceMotion
    let delay: Double
    let animation: Animation
    let since: CFTimeInterval?
    @ReducedMotion private var reduceMotion
    @State private var shown: Bool

    init(_ motion: EntranceMotion, delay: Double = 0, animation: Animation, since: CFTimeInterval? = nil, enabled: Bool = true) {
        self.motion = motion; self.delay = delay; self.animation = animation; self.since = since
        _shown = State(initialValue: !enabled || Self.isLate(delay: delay, since: since, now: CACurrentMediaTime()))
    }

    /// An element this much past its slot shows at once: a few frames of grace, so one that lands a frame after its
    /// stage began still enters.
    nonisolated static let grace: Double = 0.05

    /// The element's slot has passed: it is inserted more than `grace` after its stage began plus its delay.
    nonisolated static func isLate(delay: Double, since: CFTimeInterval?, now: CFTimeInterval) -> Bool {
        guard let since else { return false }
        return now - since > delay + grace
    }

    /// The delay still to wait when the element appears `now`: its slot measured from the stage, never below zero.
    nonisolated static func remainingDelay(_ delay: Double, since: CFTimeInterval?, now: CFTimeInterval) -> Double {
        guard let since else { return delay }
        return max(0, delay - (now - since))
    }

    func body(content: Content) -> some View {
        content
            .environment(\.glassShown, shown)
            .modifier(EntranceGeometry(motion: motion.reduced(reduceMotion), shown: shown))
            .opacity(shown ? 1 : 0)
            .onAppear {
                guard !shown else { return }
                let wait = Self.remainingDelay(delay, since: since, now: CACurrentMediaTime())
                withAnimation(wait > 0 ? animation.delay(wait) : animation) { shown = true }
            }
    }
}

/// The geometry of an entrance at rest (`shown`) or before it: one modifier chain for every motion, so the values
/// interpolate.
private struct EntranceGeometry: ViewModifier {
    let motion: EntranceMotion
    let shown: Bool
    func body(content: Content) -> some View {
        var scale: CGFloat = 1, anchor = UnitPoint.center, x: CGFloat = 0, y: CGFloat = 0, blur: CGFloat = 0
        if !shown {
            switch motion {
            case .fade: break
            case .scale(let s, let a): scale = s; anchor = a
            case .rise(let d): y = d
            case .slide(let d): x = d
            case .focus(let r): blur = r
            }
        }
        return content.blur(radius: blur).scaleEffect(scale, anchor: anchor).offset(x: x, y: y)
    }
}

extension View {
    /// A staged entrance (`Entrance`).
    func entrance(_ motion: EntranceMotion, delay: Double = 0, curve: Theme.Motion.Curve = Theme.Motion.enter,
                  since: CFTimeInterval? = nil, enabled: Bool = true) -> some View {
        modifier(Entrance(motion, delay: delay, animation: curve.animation, since: since, enabled: enabled))
    }

    /// A staged entrance on a spring (the status dot filling at a connection).
    func entrance(_ motion: EntranceMotion, delay: Double = 0, spring: Theme.Motion.Spring, since: CFTimeInterval? = nil,
                  enabled: Bool = true) -> some View {
        modifier(Entrance(motion, delay: delay, animation: spring.animation, since: since, enabled: enabled))
    }

    /// Out only, for a view whose way in is its own entrance (`Entrance`): opacity over `exit`, receding to `outScale`.
    func exitTransition(outScale: CGFloat = 1, exit: Theme.Motion.Curve = Theme.Motion.exit, anchor: UnitPoint = .center,
                        reduceMotion: Bool) -> some View {
        transition(AsymmetricTransition(
            insertion: .identity,
            removal: Presence(motion: .scale(1, anchor: anchor), outScale: reduceMotion ? 1 : outScale).animation(exit.animation)))
    }
}

/// A view a model adds and removes while its screen stays (a card, a pill, a notice, a row): in like an entrance, out
/// faster (opacity over 120 ms ease-out, with a recede to `outScale` for what was compact). The animations travel with
/// the transition, so a model's change animates without a transaction, and a keyboard path's (`Instantly`) does not.
struct Presence: Transition {
    let motion: EntranceMotion
    let outScale: CGFloat
    func body(content: Content, phase: TransitionPhase) -> some View {
        var scale: CGFloat = 1, anchor = UnitPoint.center, x: CGFloat = 0, y: CGFloat = 0
        switch phase {
        case .willAppear:
            switch motion {
            case .fade, .focus: break
            case .scale(let s, let a): scale = s; anchor = a
            case .rise(let d): y = d
            case .slide(let d): x = d
            }
        case .didDisappear:
            scale = outScale
            if case .scale(_, let a) = motion { anchor = a }
        case .identity: break
        }
        return content.environment(\.glassShown, phase.isIdentity)
            .scaleEffect(scale, anchor: anchor).offset(x: x, y: y).opacity(phase.isIdentity ? 1 : 0)
    }
}

extension View {
    /// Presence for a view a model adds and removes (`Presence`): in from `motion` after `delay` on the entrance curve,
    /// out over `exit`, receding to `outScale`. Under Reduce Motion both are fades at the same timings.
    func presence(_ motion: EntranceMotion, delay: Double = 0, outScale: CGFloat = 1, exit: Theme.Motion.Curve = Theme.Motion.exit,
                  enter: Theme.Motion.Curve = Theme.Motion.enter, reduceMotion: Bool) -> some View {
        transition(AsymmetricTransition(
            insertion: Presence(motion: motion.reduced(reduceMotion), outScale: 1).animation(enter.animation(after: delay)),
            removal: Presence(motion: .fade, outScale: reduceMotion ? 1 : outScale).animation(exit.animation)))
    }
}

// MARK: Screens

/// Which way a change of screen goes. Forward (Share, View, a Mac picked, a picture): the screen leaving recedes to
/// 0.98 and fades, and the next one stages its entrance. Back (Stop, Disconnect, Back, a cancelled picker): the screen
/// leaving fades without moving, and the one coming back returns from 0.98.
public enum NavigationDirection: Equatable, Sendable { case forward, back }

/// The direction of the change of screen under way, set before the change and read when SwiftUI applies the screens'
/// transitions. SwiftUI applies the outgoing screen's transition as it was last evaluated, before the change, so a
/// value captured there would carry the previous direction; this reference is read at that moment and carries the new
/// one.
@MainActor
final class NavigationBox {
    var direction: NavigationDirection = .forward
    /// The rank of the screen shown, for a container whose screens are ordered (`update(rank:)`).
    private(set) var rank: Int?

    /// For screens with an order (the View screen's list, code, picture): a higher rank is forward, a lower one back;
    /// the first screen takes the way its container arrived. Called from the container's body before its screens are
    /// built; idempotent for the same rank.
    func update(rank new: Int, arrival: NavigationDirection = .forward) {
        if let rank {
            if new != rank { direction = new > rank ? .forward : .back }
        } else {
            direction = arrival
        }
        rank = new
    }
}

/// A screen coming in and going (`NavigationBox`). Out: opacity over 120 ms ease-out, receding to 0.98 when going
/// forward. In, going back: from opacity 0 and scale 0.98 over the entrance curve after 60 ms. In, going forward: the
/// screen stages its own entrance (`Entrance`), so the container only appears, unless `staged` is false, where it rises
/// 6 pt. Under Reduce Motion: fades at the same timings.
struct ScreenTransition: Transition {
    let box: NavigationBox
    let staged: Bool
    let reduceMotion: Bool

    func body(content: Content, phase: TransitionPhase) -> some View {
        let back = box.direction == .back
        var scale: CGFloat = 1, y: CGFloat = 0, opacity: Double = 1
        switch phase {
        case .identity: break
        case .willAppear:
            if back { scale = Theme.Motion.screenScale; opacity = 0 }
            else if !staged { y = Theme.Motion.rise; opacity = 0 }
        case .didDisappear:
            opacity = 0
            if !back { scale = Theme.Motion.screenScale }
        }
        if reduceMotion { scale = 1; y = 0 }
        return content.environment(\.glassShown, phase.isIdentity)
            .scaleEffect(scale).offset(y: y).opacity(opacity)
    }

    /// A screen coming back waits this long, so it rises from under the one fading out rather than through it.
    static let returnDelay: Double = 0.06
}

extension View {
    /// The screen transition (`ScreenTransition`), its animations attached: the exit over 120 ms, the return after 60 ms.
    func screenTransition(_ box: NavigationBox, staged: Bool, reduceMotion: Bool) -> some View {
        transition(AsymmetricTransition(
            insertion: ScreenTransition(box: box, staged: staged, reduceMotion: reduceMotion)
                .animation(Theme.Motion.enter.animation(after: ScreenTransition.returnDelay)),
            removal: ScreenTransition(box: box, staged: staged, reduceMotion: reduceMotion).animation(Theme.Motion.exit.animation)))
    }
}

extension EnvironmentValues {
    /// How the screen being built arrived: its elements stage their entrance only when it came forward.
    @Entry var screenArrival: NavigationDirection = .forward
}

// MARK: The window's size

/// The frame that sizes the window (`.windowResizability(.contentSize)`), outermost in `RootView`: it follows the
/// screen's picture area with the window curve, 300 ms growing and 260 ms shrinking, so the window grows from its top
/// left corner to a picture and closes back in around a card instead of jumping. The size it reports is animated frame by
/// frame (`RevealLayout` is animatable) and the window follows it, which works both ways: SwiftUI's own animation of a
/// content-sized window only grows, since a smaller content size lowers the window's maximum at once (logged
/// 2026-10-12). Everything inside is laid out at its final size from the first frame and anchored top left: the
/// picture's drawable is sized once, and nothing inside moves while the edges travel. What lies below the area (the strip)
/// keeps its own height, which a keyboard path changes at once. A change on a keyboard path, or under Reduce Motion, takes
/// the new size at once.
struct AnimatedArea<Content: View>: View {
    let area: CGSize
    let content: Content
    @ReducedMotion private var reduceMotion
    /// The size the window has: the content's own size as last measured, animated. Nil until first measured.
    @State private var shown: CGSize?
    @State private var tracker = Tracker()

    /// What the last change came with: the area it was for, and whether it came on a keyboard path.
    final class Tracker {
        var area: CGSize?
        var instant = false
    }

    init(area: CGSize, @ViewBuilder content: () -> Content) {
        self.area = area; self.content = content()
    }

    var body: some View {
        let tracker = tracker
        RevealLayout(shown: shown) {
            content.onGeometryChange(for: CGSize.self, of: { $0.size }) { natural in measured(natural) }
        }
        .transaction(value: area) { tracker.instant = $0.disablesAnimations }
    }

    /// How the size shown follows a new measure of the content.
    enum Step: Equatable {
        /// It stays: nothing changed, or the content measured nothing.
        case keep
        case instant
        case animate(Theme.Motion.Curve)
    }

    /// The content took `natural`: the window follows it, on the window curve when the picture area changed with it (a
    /// picture, a screen), at once otherwise (the strip shown or wrapped, a keyboard path, Reduce Motion). An empty
    /// screen (a quit's: the window ordered out, the models let go of, the screen left as it was) measures nothing, and
    /// the window keeps its size rather than shrink toward nothing (review, 2026-10-12).
    nonisolated static func step(natural: CGSize, shown: CGSize?, areaBefore: CGSize?, area: CGSize, instant: Bool,
                                 reduceMotion: Bool) -> Step {
        guard natural.width > 0, natural.height > 0 else { return .keep }
        guard let shown else { return .instant }
        guard natural != shown else { return .keep }
        if let areaBefore, areaBefore != area, !instant, !reduceMotion { return .animate(curve(from: areaBefore, to: area)) }
        return .instant
    }

    private func measured(_ natural: CGSize) {
        let before = tracker.area
        tracker.area = area
        switch Self.step(natural: natural, shown: shown, areaBefore: before, area: area, instant: tracker.instant, reduceMotion: reduceMotion) {
        case .keep: break
        case .instant: Instantly.run { shown = natural }
        case .animate(let curve): withAnimation(curve.animation) { shown = natural }
        }
    }

    /// Growing takes the window's grow curve, shrinking its shorter one.
    nonisolated static func curve(from old: CGSize, to new: CGSize) -> Theme.Motion.Curve {
        new.width * new.height >= old.width * old.height ? Theme.Motion.windowGrow : Theme.Motion.windowShrink
    }
}

/// Sizes itself as the size shown (the window's), and places the content at its own size from the top left corner.
/// Animatable: the size shown moves frame by frame, and with it the size the window takes.
struct RevealLayout: Layout {
    var shown: CGSize?

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(shown?.width ?? 0, shown?.height ?? 0) }
        set { shown = CGSize(width: newValue.first, height: newValue.second) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let natural = subviews.first?.sizeThatFits(.unspecified) ?? .zero
        return Self.size(shown: shown, natural: natural)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let content = subviews.first else { return }
        content.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(content.sizeThatFits(.unspecified)))
    }

    /// The size shown, to the whole point, or the content's own until there is one.
    nonisolated static func size(shown: CGSize?, natural: CGSize) -> CGSize {
        guard let shown else { return natural }
        return CGSize(width: shown.width.rounded(), height: shown.height.rounded())
    }
}

// MARK: The picture's entrance

/// The picture's entrance (M6, M7): a rectangle of the background colour over the picture and the ink, opaque until the
/// picture's first frame has reached the screen, then fading from 1 to 0 over 220 ms, 40 ms after that frame. Against the
/// black window this is the picture fading in, while the Metal layer under it stays opaque at opacity 1, so its
/// compositing never changes, and the picture is never scaled. Timed from the first frame shown, not from the model's
/// event (amended 2026-10-12): the share window's first render comes some 86 ms after the capture starts on an M5, more on
/// a slower Mac, and the viewer's first keyframe a round trip after its link is ready, so a cover timed from the event
/// faded over an empty surface, or was skipped, and the picture popped in. Should no frame be reported shown, it fades on
/// its own `coverBackstop` (1 s) after the stage began (added 2026-10-12 after review: a first frame that reached the
/// screen only as a redraw once left a still picture covered). Gone once faded; built after its fade would have ended (a
/// picture shown again), it is not there at all.
struct PictureCover: View {
    /// When the picture's first frame reached the screen; nil while it has not, or when there is no stage under way.
    let shownAt: CFTimeInterval?
    /// The picture's stage is under way and its first frame has not reached the screen yet: opaque, for a second at most.
    let waiting: Bool
    /// When the picture's stage began (the capture, the link ready), which the backstop counts from.
    let since: CFTimeInterval?
    @State private var faded: Bool
    @State private var removed: Bool

    init(shownAt: CFTimeInterval?, waiting: Bool, since: CFTimeInterval?) {
        self.shownAt = shownAt; self.waiting = waiting; self.since = since
        let now = CACurrentMediaTime()
        let late = waiting ? Self.isLate(waitingSince: since, now: now) : Self.isLate(shownAt: shownAt, now: now)
        _faded = State(initialValue: late)
        _removed = State(initialValue: late)
    }

    /// A cover built `now` for a first frame shown at `shownAt` has nothing left to do: its fade would have ended. Any
    /// later than that, a slow first render still fades the picture in, with what is left of its 40 ms.
    nonisolated static func isLate(shownAt: CFTimeInterval?, now: CFTimeInterval) -> Bool {
        guard let shownAt else { return true }
        return now - shownAt > Theme.Motion.coverDelay + Theme.Motion.enter.duration
    }

    /// A cover built `now`, still waiting for the first frame of a stage that began at `since`, has nothing left to do
    /// once its backstop's fade would have ended.
    nonisolated static func isLate(waitingSince since: CFTimeInterval?, now: CFTimeInterval) -> Bool {
        guard let since else { return false }
        return now - since > Theme.Motion.coverBackstop + Theme.Motion.enter.duration
    }

    /// How long a cover still waiting `now` waits before it fades on its own: what is left of the backstop since the
    /// stage began.
    nonisolated static func backstopDelay(since: CFTimeInterval?, now: CFTimeInterval) -> Double {
        Entrance.remainingDelay(Theme.Motion.coverBackstop, since: since, now: now)
    }

    var body: some View {
        if !removed {
            Theme.Colors.background
                .opacity(faded ? 0 : 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .onAppear { if !waiting { fadeFromTheFirstFrame() } }
                .onChange(of: waiting) { _, now in if !now { fadeFromTheFirstFrame() } }
                // The backstop: cancelled when the first frame comes (`waiting` changes) or the cover goes.
                .task(id: waiting) {
                    guard waiting else { return }
                    try? await Task.sleep(for: .seconds(Self.backstopDelay(since: since, now: CACurrentMediaTime())))
                    guard !Task.isCancelled else { return }
                    fade(after: 0)
                }
        }
    }

    private func fadeFromTheFirstFrame() {
        fade(after: Entrance.remainingDelay(Theme.Motion.coverDelay, since: shownAt, now: CACurrentMediaTime()))
    }

    private func fade(after wait: Double) {
        guard !faded else { return }
        withAnimation(Theme.Motion.enter.animation(after: wait)) { faded = true } completion: { removed = true }
    }
}
