import SwiftUI
import AppKit
import QuartzCore

// Two small things that carry a lot of the app's feeling: the status dot that breathes while a link reconnects, and the
// pairing code that arrives as if typed in gold.

/// A status dot drawn by Core Animation (spec 11, M9, M10): green while connected, gold while reconnecting, and while
/// `breathing` its opacity goes 1 ↔ 0.35 over 1.2 s each way on the render server, so a loop over a live picture never
/// ticks the main thread (only a change of state touches it). Every dot breathing at once shares one phase, so the
/// viewer's pill and its chip breathe together. A change of colour takes 200 ms, ease. Under Reduce Motion it is still.
struct PulseDot: NSViewRepresentable {
    let color: NSColor
    let breathing: Bool
    var size: CGFloat = 6

    func makeNSView(context: Context) -> PulseDotView { PulseDotView(color: color) }
    func updateNSView(_ view: PulseDotView, context: Context) {
        view.update(color: color, breathing: breathing && !context.environment.reducesMotion)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PulseDotView, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }
}

final class PulseDotView: NSView {
    private let dot = CALayer()
    private var color: NSColor
    private(set) var breathing = false

    /// The colour change, 200 ms, ease.
    static let recolour = Theme.Motion.Curve(Theme.Motion.ease, 0.2)
    /// When the dots breathing now began their shared breath (`CACurrentMediaTime`), and how many breathe.
    private static var phaseOrigin: CFTimeInterval?
    private static var breathers = 0

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        dot.backgroundColor = color.cgColor
        layer?.addSublayer(dot)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        dot.frame = bounds
        dot.cornerRadius = min(bounds.width, bounds.height) / 2
        CATransaction.commit()
    }

    /// Two colours alike to the eye (a SwiftUI colour converted anew on every update is a new object each time).
    static func same(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let a = a.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else { return a == b }
        return abs(a.redComponent - b.redComponent) < 0.002 && abs(a.greenComponent - b.greenComponent) < 0.002
            && abs(a.blueComponent - b.blueComponent) < 0.002 && abs(a.alphaComponent - b.alphaComponent) < 0.002
    }

    func update(color new: NSColor, breathing shouldBreathe: Bool) {
        if !Self.same(new, color) {
            let animation = CABasicAnimation(keyPath: "backgroundColor")
            animation.fromValue = dot.presentation()?.backgroundColor ?? dot.backgroundColor
            animation.toValue = new.cgColor
            animation.duration = Self.recolour.duration
            animation.timingFunction = Self.recolour.timingFunction
            CATransaction.begin(); CATransaction.setDisableActions(true)
            dot.backgroundColor = new.cgColor
            CATransaction.commit()
            dot.add(animation, forKey: "colour")
            color = new
        }
        guard shouldBreathe != breathing else { return }
        breathing = shouldBreathe
        if shouldBreathe { startBreathing() } else { stopBreathing() }
    }

    private func startBreathing() {
        if Self.breathers == 0 { Self.phaseOrigin = CACurrentMediaTime() + Self.recolour.duration }
        Self.breathers += 1
        let breath = CABasicAnimation(keyPath: "opacity")
        breath.fromValue = 1
        breath.toValue = Theme.Motion.breatheLow
        breath.duration = Theme.Motion.breathe.duration
        breath.timingFunction = Theme.Motion.breathe.timingFunction
        breath.autoreverses = true
        breath.repeatCount = .infinity
        breath.beginTime = dot.convertTime(Self.phaseOrigin ?? CACurrentMediaTime(), from: nil)
        breath.fillMode = .backwards
        dot.add(breath, forKey: "breath")
    }

    private func stopBreathing() {
        Self.breathers = max(0, Self.breathers - 1)
        if Self.breathers == 0 { Self.phaseOrigin = nil }
        let current = dot.presentation()?.opacity ?? 1
        dot.removeAnimation(forKey: "breath")
        let settle = CABasicAnimation(keyPath: "opacity")
        settle.fromValue = current
        settle.toValue = 1
        settle.duration = Self.recolour.duration
        settle.timingFunction = Self.recolour.timingFunction
        dot.add(settle, forKey: "settle")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A dot taken off the screen while it breathes no longer counts towards the shared breath.
        if window == nil, breathing { breathing = false; Self.breathers = max(0, Self.breathers - 1); if Self.breathers == 0 { Self.phaseOrigin = nil } }
    }
}

/// The pairing code (spec 11, M8): it arrives as if typed in gold, digit by digit, 40 ms apart, each rising 4 pt over
/// 160 ms on the strong ease-out and settling from the gold highlight to gold over 360 ms, like ink before it settles. A
/// new code (three wrong codes rotate it) lifts the old digits out together over 120 ms, then types itself. At rest it
/// is exactly the one `Text` it always was, tracking 6 and all: while it types, the same text is drawn as one run with
/// each digit's opacity, colour and baseline set for the moment, so no glyph moves when it comes to rest. VoiceOver reads
/// one element. Under Reduce Motion the code fades in as one over 150 ms, and a new one crossfades.
struct TypedCode: View {
    let code: String
    /// The first code types this long after its stage began (`since`); one that lands after its slot is simply there.
    let delay: Double
    let since: CFTimeInterval?
    @ReducedMotion private var reduceMotion
    @State private var typing: Typing?

    struct Typing: Equatable {
        /// The code going out, lifted away during `outgoing` seconds before `start`.
        var old: String?
        var new: String
        /// When digit 0 starts (`CACurrentMediaTime`).
        var start: CFTimeInterval
    }

    nonisolated static let rise: CGFloat = 4
    nonisolated static let digitIn = Theme.Motion.enter.over(0.16)
    nonisolated static let digitSettle = Theme.Motion.Curve(Theme.Motion.systemEaseInOut, 0.36)
    nonisolated static let outgoing = Theme.Motion.exit
    /// The new code's first digit waits for the old ones to go.
    nonisolated static var newCodeDelay: Double { outgoing.duration }

    /// When digit `index` starts after digit 0: 40 ms apart.
    nonisolated static func offset(of index: Int) -> Double { Double(index) * Theme.Motion.stagger }
    /// How long a code takes to come to rest from its first digit.
    nonisolated static func duration(digits: Int) -> Double { offset(of: max(0, digits - 1)) + digitSettle.duration }

    /// One digit at `elapsed` seconds after digit 0 started: its opacity, how far below its place it still is, and how
    /// far its colour has gone from the highlight to gold (0...1).
    nonisolated static func digit(_ index: Int, at elapsed: Double) -> (opacity: Double, drop: CGFloat, settled: Double) {
        let t = elapsed - offset(of: index)
        let p = digitIn.progress(at: t)
        return (p, rise * CGFloat(1 - p), digitSettle.progress(at: t))
    }

    init(code: String, delay: Double, since: CFTimeInterval?) {
        self.code = code; self.delay = delay; self.since = since
        let now = CACurrentMediaTime()
        let types = since.map { !Entrance.isLate(delay: delay, since: $0, now: now) } ?? false
        _typing = State(initialValue: types ? Typing(old: nil, new: code, start: (since ?? now) + delay) : nil)
    }

    private var resting: Text { Text(code).font(Theme.Fonts.code(34)).tracking(6) }

    var body: some View {
        Group {
            if reduceMotion {
                resting.foregroundStyle(Theme.Colors.gold)
                    .id(code)
                    .transition(.opacity.animation(Theme.Motion.reducedFade.animation))
                    .entrance(.fade, delay: delay, curve: Theme.Motion.reducedFade, since: since, enabled: since != nil)
            } else {
                resting.foregroundStyle(Theme.Colors.gold)
                    .opacity(typing == nil ? 1 : 0)
                    .overlay(alignment: Alignment(horizontal: .leading, vertical: .firstTextBaseline)) {
                        if let typing {
                            TimelineView(.animation) { context in
                                Self.typed(typing, now: context.date.timeIntervalSinceReferenceDate - Self.clockOffset)
                            }
                        }
                    }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Code \(code.map(String.init).joined(separator: " "))")
        .onChange(of: code) { old, new in
            guard !reduceMotion else { return }
            typing = Typing(old: old, new: new, start: CACurrentMediaTime() + Self.newCodeDelay)
        }
        .task(id: typing) {
            guard let typing else { return }
            let end = typing.start + Self.duration(digits: typing.new.count)
            let wait = end - CACurrentMediaTime()
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled, self.typing == typing else { return }
            self.typing = nil
        }
    }

    /// `TimelineView` hands over dates; the schedule is kept in `CACurrentMediaTime`. The two clocks differ by a constant.
    private static var clockOffset: Double { Date.timeIntervalSinceReferenceDate - CACurrentMediaTime() }

    /// The code as one run of text at `now`: the old digits lifting away, or the new ones typing in.
    static func typed(_ typing: Typing, now: CFTimeInterval) -> Text {
        let elapsed = now - typing.start
        if let old = typing.old, elapsed < 0 {
            let p = outgoing.progress(at: elapsed + outgoing.duration)
            return run(old) { _ in (1 - p, -rise * CGFloat(p), 1) }
        }
        return run(typing.new) { digit($0, at: max(0, elapsed)) }
    }

    private static func run(_ digits: String, _ look: (Int) -> (opacity: Double, drop: CGFloat, settled: Double)) -> Text {
        var text = Text("")
        for (index, character) in digits.enumerated() {
            let (opacity, drop, settled) = look(index)
            text = text + Text(String(character))
                .foregroundStyle(colour(settled: settled).opacity(opacity))
                .baselineOffset(-drop)
        }
        return text.font(Theme.Fonts.code(34)).tracking(6)
    }

    /// The highlight (#d8ba7e) to gold (#c9a86a), `settled` of the way.
    nonisolated static func colour(settled: Double) -> Color {
        let from = (216.0, 186.0, 126.0), to = (201.0, 168.0, 106.0)
        let s = min(max(settled, 0), 1)
        return Color(.sRGB, red: (from.0 + (to.0 - from.0) * s) / 255, green: (from.1 + (to.1 - from.1) * s) / 255,
                     blue: (from.2 + (to.2 - from.2) * s) / 255, opacity: 1)
    }
}
