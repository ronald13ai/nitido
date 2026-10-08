import SwiftUI

/// Liquid Glass on macOS 26, thin material with a hairline on macOS 15.
public struct GlassCard<Content: View>: View {
    let radius: CGFloat
    let content: Content
    public init(radius: CGFloat = Theme.cardRadius, @ViewBuilder content: () -> Content) { self.radius = radius; self.content = content() }
    public var body: some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius))
        } else {
            content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius))
                .overlay(RoundedRectangle(cornerRadius: radius).stroke(Theme.Colors.hairline, lineWidth: 1))
        }
    }
}

/// Full-width glass strip (the telemetry bar).
public struct GlassBar: ViewModifier {
    public func body(content: Content) -> some View {
        if #available(macOS 26, *) { content.glassEffect(.regular, in: Rectangle()) }
        else { content.background(.ultraThinMaterial).overlay(alignment: .top) { Rectangle().fill(Theme.Colors.hairline).frame(height: 1) } }
    }
}

/// Every pressable element answers the press: scale 0.97 over 120 ms, opacity only under Reduce Motion.
public struct PressFeedback: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(Theme.Motion.press, value: configuration.isPressed)
    }
}

public struct GoldButton: View {
    let title: String, action: () -> Void
    public init(_ title: String, action: @escaping () -> Void) { self.title = title; self.action = action }
    public var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.Colors.background)
                .padding(.horizontal, 22).padding(.vertical, 9)
                .background(Theme.Colors.goldGradient, in: Capsule())
        }.buttonStyle(PressFeedback())
    }
}

public struct QuietButton: View {
    let title: String, action: () -> Void
    public init(_ title: String, action: @escaping () -> Void) { self.title = title; self.action = action }
    public var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.Colors.text)
                .padding(.horizontal, 22).padding(.vertical, 9)
                .overlay(Capsule().stroke(Theme.Colors.hairline, lineWidth: 1))
        }.buttonStyle(PressFeedback())
    }
}

/// A thin gold ring that draws itself once when `trigger` changes (a new connection), then stays.
public struct ConnectRing: View {
    let trigger: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 0
    public init(trigger: Int) { self.trigger = trigger }
    public var body: some View {
        Circle().trim(from: 0, to: progress)
            .stroke(Theme.Colors.gold, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .onAppear { animate() }
            .onChange(of: trigger) { _, _ in progress = 0; animate() }
    }
    private func animate() {
        if reduceMotion { progress = 1; return }
        withAnimation(Theme.Motion.connect) { progress = 1 }
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
