import SwiftUI

/// Glass for what sits over a live picture: the pairing panel, the codec loop panel, the sharer chip, the notices and
/// the failure cards. Liquid Glass on macOS 26 with a dark backing inside it (`Theme.Colors.glassBacking`), so the gold
/// and the text on it keep their contrast over a white document whether the window is key or not; thin material, the
/// surface at 80 % and a hairline on macOS 15. Over flat black glass bends nothing, so the screens without a picture
/// draw solid surfaces instead (`WelcomeView`, `SolidCard`).
public struct Glass<S: InsettableShape>: ViewModifier {
    let shape: S
    public init(in shape: S) { self.shape = shape }
    public func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            // The backing is its own layer above the glass, not the content's background under `glassEffect`: a small
            // piece of glass (the sharer chip) over a light picture adapts to it with a light layer of its own, which
            // otherwise lands over the backing (#47474a over a white document instead of #1c1c21).
            content.background {
                ZStack {
                    Color.clear.glassEffect(.regular, in: shape)
                    shape.fill(Theme.Colors.glassBacking)
                }
            }
        } else {
            content
                .background(Theme.Colors.surface.opacity(0.80), in: shape)
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(Theme.Colors.hairline, lineWidth: 1))
        }
    }
}

public extension View {
    func glass<S: InsettableShape>(in shape: S) -> some View { modifier(Glass(in: shape)) }
}

/// A glass card with the card radius (14), continuous corners (spec 11).
public struct GlassCard<Content: View>: View {
    let radius: CGFloat
    let content: Content
    public init(radius: CGFloat = Theme.cardRadius, @ViewBuilder content: () -> Content) { self.radius = radius; self.content = content() }
    public var body: some View {
        content.glass(in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// The card of a screen without a picture (Welcome): solid surface, a hairline border, and a faint highlight along its
/// top edge, the way light catches the rim of a dark object.
public struct SolidCard<Content: View>: View {
    let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
        content
            .background(shape.fill(Theme.Colors.surface))
            .overlay(
                shape.fill(LinearGradient(stops: [.init(color: Theme.Colors.text.opacity(0.06), location: 0),
                                                  .init(color: .clear, location: 0.4)],
                                          startPoint: .top, endPoint: .bottom))
                    .allowsHitTesting(false)
            )
            .overlay(shape.strokeBorder(Theme.Colors.hairline, lineWidth: 1))
    }
}

/// Every pressable element answers the press (scale 0.97 over 120 ms, opacity only under Reduce Motion) and the pointer
/// (a 4 % lift in brightness over 120 ms on the same curve). `held` keeps the pressed look on while ⏎ runs the button
/// (`GoldButton`).
public struct PressFeedback: ButtonStyle {
    var held = false
    public init() {}
    init(held: Bool) { self.held = held }
    public func makeBody(configuration: Configuration) -> some View {
        PressBody(label: configuration.label, pressed: configuration.isPressed || held)
    }
}

private struct PressBody<Label: View>: View {
    let label: Label
    let pressed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false
    var body: some View {
        label
            .brightness(hovered && isEnabled && !pressed ? 0.04 : 0)
            .scaleEffect(pressed && !reduceMotion ? 0.97 : 1)
            .opacity(pressed ? 0.88 : 1)
            .animation(Theme.Motion.press, value: pressed)
            .animation(Theme.Motion.hover, value: hovered)
            .onHover { hovered = $0 }
    }
}

/// The width every paired button shares, so Share and View, Back and Connect read as a pair: 96 pt at least.
let buttonMinWidth: CGFloat = 96

/// The way forward. Spec 11: controls take the 10 pt control radius, as the rows and notices beside them do. 32 pt tall
/// (8 pt above and below 13 pt text), 96 pt wide at least. Disabled, it keeps its shape as a faint gold fill with a gold
/// label, instead of the whole button fading to khaki.
///
/// `isDefault`: ⏎ presses it (an invisible system button carries the shortcut, since this one draws its own shape), and
/// so does a change of `submits` (a field's ⏎). Either way the button shows its press for 120 ms, then runs the action.
public struct GoldButton: View {
    let title: String, action: () -> Void
    let isDefault: Bool
    let submits: Int
    @Environment(\.isEnabled) private var isEnabled
    @State private var held = false
    public init(_ title: String, isDefault: Bool = false, submits: Int = 0, action: @escaping () -> Void) {
        self.title = title; self.isDefault = isDefault; self.submits = submits; self.action = action
    }
    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isEnabled ? Theme.Colors.background : Theme.Colors.gold.opacity(0.45))
                .padding(.horizontal, 20).padding(.vertical, 8)
                .frame(minWidth: buttonMinWidth)
                .background {
                    if isEnabled { shape.fill(Theme.Colors.goldGradient) } else { shape.fill(Theme.Colors.gold.opacity(0.16)) }
                }
                .contentShape(shape)
        }
        .buttonStyle(PressFeedback(held: held))
        .background { if isDefault { DefaultAction(action: pressThenRun) } }
        .onChange(of: submits) { _, _ in pressThenRun() }
    }

    /// The press ⏎ makes: held for 120 ms (`Theme.Motion.press`, which `PressFeedback` animates), then the action. A
    /// second ⏎ meanwhile (the field's and the hidden button's, for one key press) does nothing more.
    private func pressThenRun() {
        guard isEnabled, !held else { return }
        held = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            held = false
            action()
        }
    }
}

public struct QuietButton: View {
    let title: String, action: () -> Void
    public init(_ title: String, action: @escaping () -> Void) { self.title = title; self.action = action }
    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.Colors.text)
                .padding(.horizontal, 20).padding(.vertical, 8)
                .frame(minWidth: buttonMinWidth)
                // A border, not a stroke: the 1 pt line stays inside the button's bounds instead of straddling them.
                .background(shape.fill(Theme.Colors.quietFill))
                .overlay(shape.strokeBorder(Theme.Colors.quietBorder, lineWidth: 1))
                .contentShape(shape)
        }.buttonStyle(PressFeedback())
    }
}

/// The default action (⏎) for a screen whose buttons draw themselves (`GoldButton`): an invisible system button that
/// takes no room, like `EscapeStops`.
struct DefaultAction: View {
    let action: () -> Void
    var body: some View {
        Button("", action: action)
            .keyboardShortcut(.defaultAction)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }
}

/// The connect moment (spec 11): a thin gold ring draws itself once around the peer's row or chip per connection
/// (`trigger`, a model's connection count) with the connect spring, then over 0.6 s eases down to a 1 pt hairline,
/// which is where the spring's bounce shows: as a settle. The model keeps the last connection it played for
/// (`shownFor`), so a screen shown again draws it at rest instead of playing it again. While the link is reconnecting the
/// ring fades out in 150 ms, so the badge never says connected when it is not. Under Reduce Motion there is no ring.
public struct ConnectRing: View {
    /// How the ring starts when it appears or its trigger changes.
    enum Start: Equatable {
        /// Reduce Motion: no ring at all.
        case hidden
        /// Already played for this connection: drawn at rest.
        case drawn
        /// A connection it has not played for: it draws itself.
        case animate
    }

    nonisolated static func start(trigger: Int, shownFor: Int, reduceMotion: Bool) -> Start {
        guard !reduceMotion else { return .hidden }
        return trigger > shownFor ? .animate : .drawn
    }

    let trigger: Int
    @Binding var shownFor: Int
    let reconnecting: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 0
    @State private var settled = false
    public init(trigger: Int, shownFor: Binding<Int>, reconnecting: Bool = false) {
        self.trigger = trigger; _shownFor = shownFor; self.reconnecting = reconnecting
    }
    public var body: some View {
        Capsule(style: .continuous).inset(by: -4).trim(from: 0, to: progress)
            .stroke(settled ? Theme.Colors.hairline : Theme.Colors.gold,
                    style: StrokeStyle(lineWidth: settled ? 1 : 1.5, lineCap: .round))
            .opacity(reduceMotion || reconnecting ? 0 : 1)
            .animation(.easeOut(duration: 0.15), value: reconnecting)
            .allowsHitTesting(false)
            .onAppear { begin() }
            .onChange(of: trigger) { _, _ in begin() }
    }
    private func begin() {
        switch Self.start(trigger: trigger, shownFor: shownFor, reduceMotion: reduceMotion) {
        case .hidden: progress = 0
        case .drawn: progress = 1; settled = true
        case .animate:
            progress = 0; settled = false
            withAnimation(Theme.Motion.connect) { progress = 1 } completion: {
                withAnimation(Theme.Motion.settle) { settled = true }
            }
        }
        shownFor = trigger
    }
}

/// Entrance: opacity 0 and scale 0.96 to rest, strong ease-out, optional delay for staggering.
public struct Appear: ViewModifier {
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    public func body(content: Content) -> some View {
        content.opacity(shown ? 1 : 0).scaleEffect(shown || reduceMotion ? 1 : 0.96)
            .onAppear { withAnimation(Theme.Motion.enter.delay(delay)) { shown = true } }
    }
}
public extension View { func appear(delay: Double = 0) -> some View { modifier(Appear(delay: delay)) } }

/// A screen coming in and going: in with the entrance (opacity and scale 0.98, the scale left out under Reduce Motion),
/// out faster, opacity only over 120 ms (spec 11: exits are faster than entrances).
public struct ScreenTransition: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public func body(content: Content) -> some View {
        content.transition(.asymmetric(
            insertion: reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)),
            removal: .opacity.animation(Theme.Motion.exit)))
    }
}
public extension View { func screenTransition() -> some View { modifier(ScreenTransition()) } }

/// One short horizontal shake (180 ms) when `trigger` changes; nothing under Reduce Motion.
public struct Shake: ViewModifier {
    let trigger: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var offset: CGFloat = 0
    public func body(content: Content) -> some View {
        content.offset(x: offset).onChange(of: trigger) { _, _ in
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 0.045)) { offset = -6 }
            withAnimation(.linear(duration: 0.045).delay(0.045)) { offset = 6 }
            withAnimation(.linear(duration: 0.045).delay(0.09)) { offset = -3 }
            withAnimation(.linear(duration: 0.045).delay(0.135)) { offset = 0 }
        }
    }
}
public extension View { func shake(trigger: Int) -> some View { modifier(Shake(trigger: trigger)) } }

/// A failure or a wait, laid out the same everywhere (spec 9 and 12): an SF Symbol in gold, a title, a secondary body,
/// then the actions, the first of which is the way forward (gold). On glass, since it sits over the picture.
public struct MessageCard: View {
    public struct Action {
        let title: String
        let run: () -> Void
        public init(_ title: String, run: @escaping () -> Void) { self.title = title; self.run = run }
    }
    let symbol: String, title: String, message: String
    var note: String?
    var actions: [Action]
    /// Over a picture the card is glass; over the bare background (no picture yet) it is the solid card, as Welcome's.
    var overPicture: Bool
    public init(symbol: String, title: String, message: String, note: String? = nil, actions: [Action] = [], overPicture: Bool = true) {
        self.symbol = symbol; self.title = title; self.message = message; self.note = note; self.actions = actions
        self.overPicture = overPicture
    }
    public var body: some View {
        if overPicture { GlassCard { content } } else { SolidCard { content } }
    }

    private var content: some View {
        VStack(spacing: 0) {
            Image(systemName: symbol).font(.system(size: 28, weight: .light)).foregroundStyle(Theme.Colors.gold)
                .accessibilityHidden(true)
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.Colors.text)
                .multilineTextAlignment(.center).padding(.top, 12)
            Text(message).font(.system(size: 13)).foregroundStyle(Theme.Colors.secondaryText)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            if let note {
                Text(note).font(.system(size: 12)).foregroundStyle(Theme.Colors.secondaryText)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            }
            if !actions.isEmpty {
                HStack(spacing: 12) {
                    // Quiet ones first, the way forward last, where ⏎ lands (macOS: the default button on the right).
                    ForEach(Array(actions.enumerated().reversed()), id: \.offset) { index, action in
                        if index == 0 {
                            GoldButton(action.title, isDefault: true, action: action.run)
                        } else {
                            QuietButton(action.title, action: action.run)
                        }
                    }
                }
                .padding(.top, 24)
            }
        }
        .padding(.horizontal, 32).padding(.vertical, 28)
        .frame(maxWidth: 380)
    }
}
