import SwiftUI
import AppKit
import CoreText
import QuartzCore
import os

public enum Theme {
    /// The palette (spec 11) as sRGB values, defined once: `Colors` for SwiftUI, `CanvasColors` for the layers AppKit
    /// draws (the ink canvas). Spec 11's soft red has no token: the one destructive confirmation is the system's dialog.
    enum Hex {
        static let background: UInt32 = 0x08090c
        static let surface: UInt32 = 0x0e1015
        static let hairline: UInt32 = 0x2b2e38
        static let muted: UInt32 = 0x3a3e4a
        static let secondaryText: UInt32 = 0x8a8f9c
        static let text: UInt32 = 0xf2f3f5
        static let gold: UInt32 = 0xc9a86a
        static let goldHighlight: UInt32 = 0xd8ba7e
        static let cream: UInt32 = 0xf3e3ba
        static let success: UInt32 = 0x62c37e
    }

    public enum Colors {
        public static let background = Color(hex: Hex.background)
        public static let surface = Color(hex: Hex.surface)
        public static let hairline = Color(hex: Hex.hairline)
        /// Hairlines and inactive states only: about 1.9:1 on the background, too faint for text.
        public static let muted = Color(hex: Hex.muted)
        /// Secondary text (subtitles, small-caps captions, the strip's labels and units): 6.2:1 on the background,
        /// 5.9:1 on the surface.
        public static let secondaryText = Color(hex: Hex.secondaryText)
        public static let text = Color(hex: Hex.text)
        public static let gold = Color(hex: Hex.gold)
        public static let goldHighlight = Color(hex: Hex.goldHighlight)
        /// The wordmark's warm white, so the cream mark and the gold credit carry the maison's warmth together.
        public static let cream = Color(hex: Hex.cream)
        public static let success = Color(hex: Hex.success)
        public static let goldGradient = LinearGradient(
            colors: [gold, goldHighlight], startPoint: .topLeading, endPoint: .bottomTrailing)
        /// The quiet button's fill and border: text at 5 % and 12 %, so the pair reads on the surface and on glass alike,
        /// where the hairline token disappears.
        public static let quietFill = text.opacity(0.05)
        public static let quietBorder = text.opacity(0.12)
        /// Laid inside the Liquid Glass over the picture (`GlassCard`), so a panel stays dark over a white document
        /// whether the window is key or not. Bare, macOS 26 draws the glass of a window that is not key (the sharer's
        /// usual case: the person works in the window they share) as an opaque grey, #5e5e5f over white, where the gold
        /// code is 2.9:1. A glass tint does not darken it (`.tint` at 62 % of the background measured #6f6f6f, lighter);
        /// this backing does: #1c1c21 over white, gold 7.5:1 and secondary text 5.3:1.
        public static let glassBacking = background.opacity(0.80)
    }

    /// The ink canvas's colours (spec 11): this side's strokes and the peer's cursor in gold, the peer's strokes and its
    /// cursor's name in cream, the name on a pill of the surface.
    enum CanvasColors {
        static let gold = NSColor(hex: Hex.gold)
        static let cream = NSColor(hex: Hex.cream)
        /// The pill under the peer's name, and its hairline.
        static let surface = NSColor(hex: Hex.surface)
        static let hairline = NSColor(hex: Hex.hairline)
    }

    public enum Fonts {
        public static func wordmark(_ size: CGFloat) -> Font {
            .custom("Cormorant Garamond", size: size).italic()
        }
        public static func smallCaps(_ size: CGFloat) -> Font {
            .custom("Marcellus", size: size)
        }
        public static func figures(_ size: CGFloat) -> Font {
            .system(size: size, weight: .medium, design: .monospaced)
        }
        /// The pairing code, wherever it is shown or typed: SF Pro light with tabular digits, large enough to read
        /// across a desk. Not SF Mono, whose slashed zero reads technical rather than maison.
        public static func code(_ size: CGFloat = 34) -> Font {
            .system(size: size, weight: .light).monospacedDigit()
        }
    }

    /// Every motion value in one place (spec 11, and the choreography per moment): curves and springs as numbers, so the
    /// spec, the code and the tests read the same values.
    public enum Motion {
        /// A cubic Bézier timing curve, `cubic-bezier(x1, y1, x2, y2)`, over `duration` seconds.
        public struct Curve: Equatable, Sendable {
            public let x1: Double, y1: Double, x2: Double, y2: Double
            public let duration: Double
            public init(_ points: (Double, Double, Double, Double), _ duration: Double) {
                (x1, y1, x2, y2) = points; self.duration = duration
            }
            public var animation: Animation { .timingCurve(x1, y1, x2, y2, duration: duration) }
            /// The same curve after `delay` seconds.
            public func animation(after delay: Double) -> Animation { delay > 0 ? animation.delay(delay) : animation }
            /// The same curve over another duration.
            public func over(_ seconds: Double) -> Curve { Curve((x1, y1, x2, y2), seconds) }
            /// The curve for Core Animation (the ink, the breathing dot, the sparkline).
            public var timingFunction: CAMediaTimingFunction {
                CAMediaTimingFunction(controlPoints: Float(x1), Float(y1), Float(x2), Float(y2))
            }
            /// How far along the curve is at `time` seconds after it started: 0 before, 1 after, the curve's value in
            /// between (the x of the Bézier solved for the time, then its y).
            public func progress(at time: Double) -> Double {
                guard duration > 0 else { return time >= 0 ? 1 : 0 }
                let x = min(max(time / duration, 0), 1)
                if x == 0 || x == 1 { return x }
                return Self.bezier(y1, y2, at: Self.parameter(forX: x, x1, x2))
            }
            static func bezier(_ p1: Double, _ p2: Double, at t: Double) -> Double {
                let u = 1 - t
                return 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t
            }
            /// The Bézier parameter whose x is `x`: Newton's method, then bisection should it not converge.
            static func parameter(forX x: Double, _ x1: Double, _ x2: Double) -> Double {
                var t = x
                for _ in 0..<8 {
                    let error = bezier(x1, x2, at: t) - x
                    if abs(error) < 1e-7 { return t }
                    let u = 1 - t
                    let slope = 3 * u * u * x1 + 6 * u * t * (x2 - x1) + 3 * t * t * (1 - x2)
                    if abs(slope) < 1e-6 { break }
                    t = min(max(t - error / slope, 0), 1)
                }
                var low = 0.0, high = 1.0
                t = x
                for _ in 0..<40 {
                    let value = bezier(x1, x2, at: t)
                    if abs(value - x) < 1e-7 { break }
                    if value < x { low = t } else { high = t }
                    t = (low + high) / 2
                }
                return t
            }
        }

        /// Apple's spring, `spring(duration:bounce:)`: for what feels alive, and for what a drag can interrupt.
        public struct Spring: Equatable, Sendable {
            public let duration: Double, bounce: Double
            public init(duration: Double, bounce: Double) { self.duration = duration; self.bounce = bounce }
            public var animation: Animation { .spring(duration: duration, bounce: bounce) }
            public func animation(after delay: Double) -> Animation { delay > 0 ? animation.delay(delay) : animation }
        }

        /// The named curves. Strong ease-out for what enters; strong ease-in-out for what moves on screen; ease for a
        /// colour under the pointer; the system's ease-in-out for loops, settles and the launch's glint, where the strong
        /// one would stall at each end.
        public static let strongEaseOut = (0.23, 1.0, 0.32, 1.0)
        public static let strongEaseInOut = (0.77, 0.0, 0.175, 1.0)
        public static let ease = (0.25, 0.1, 0.25, 1.0)
        public static let systemEaseInOut = (0.42, 0.0, 0.58, 1.0)
        public static let easeOut = (0.0, 0.0, 0.58, 1.0)

        /// Every entrance: strong ease-out, 220 ms.
        public static let enter = Curve(strongEaseOut, 0.22)
        /// Press in and out, and ⏎ held on a gold button: strong ease-out, 120 ms.
        public static let press = Curve(strongEaseOut, 0.12)
        /// Brightness and fill under the pointer: a colour change, so ease, over 160 ms (soft rather than a flicker
        /// when the pointer sweeps a row of buttons).
        public static let hover = Curve(ease, 0.16)
        /// Every exit, faster than the entrance: ease-out, 120 ms, opacity only unless a moment says otherwise.
        public static let exit = Curve(easeOut, 0.12)
        /// What moves or resizes on screen: a panel growing, notices restacking, the strip's figures making room.
        public static let move = Curve(strongEaseInOut, 0.24)
        /// The window's frame when a picture arrives (300 ms) and when it leaves (260 ms), from its top left corner.
        public static let windowGrow = Curve(strongEaseInOut, 0.30)
        public static let windowShrink = Curve(strongEaseInOut, 0.26)
        /// The wordmark coming into focus at launch, from an 8 pt blur.
        public static let focus = Curve(strongEaseOut, 0.24)
        public static let focusBlur: CGFloat = 8
        /// A figure's numeric roll on the strip and the quality label.
        public static let figure = Curve(strongEaseOut, 0.18)
        /// The connect ring drawing itself, once per connection.
        public static let connect = Spring(duration: 0.5, bounce: 0.2)
        /// The ring easing down to a hairline once drawn.
        public static let settle = Curve(systemEaseInOut, 0.6)
        /// The status dot filling at a connection.
        public static let alive = Spring(duration: 0.35, bounce: 0.3)
        /// The divider dot under the pointer's drag; interruptible.
        public static let grab = Spring(duration: 0.25, bounce: 0.2)
        /// The divider dot let go: back to rest without a bounce.
        public static let letGo = Spring(duration: 0.3, bounce: 0)
        /// The gold dot of a reconnect: 1.2 s each way, repeating, on the system ease-in-out (a near sine; a 2.4 s
        /// breath, never a blink).
        public static let breathe = Curve(systemEaseInOut, 1.2)
        public static let breatheLow: Float = 0.35
        /// The one gold glint across the wordmark at launch, on the system ease-in-out (amended 2026-10-12 from the strong
        /// one): its band starts and ends clear of the glyphs, where the strong curve spends most of its time, so it
        /// crossed the letters in about 270 ms of the 760 at full speed, a flick; this curve keeps it on them for about 410.
        public static let shimmer = Curve(systemEaseInOut, 0.76)
        public static let shimmerDelay: Double = 0.44
        /// The divider line drawing itself up from its handle.
        public static let reveal = Curve(strongEaseInOut, 0.22)
        /// Between siblings entering together.
        public static let stagger: Double = 0.04

        /// Scales and travels. Compact things (buttons, chips, cards, panels) scale in from 0.96, a 12 pt dot from
        /// 0.8 and a 6 pt dot from 0.5, where 0.96 would move less than half a point; wide rows and lines of text rise
        /// 6 pt instead. A screen going forward recedes to 0.98, and one coming back returns from it.
        public static let enterScale: CGFloat = 0.96
        public static let screenScale: CGFloat = 0.98
        public static let pressScale: CGFloat = 0.97
        /// Rows wider than 300 pt: the same 4 pt of travel a side as 0.97 on a 260 pt control.
        public static let pressScaleWide: CGFloat = 0.985
        public static let pressOpacity: Double = 0.88
        public static let hoverBrightness: Double = 0.04
        public static let rise: CGFloat = 6
        /// Under Reduce Motion a fade stands in for what moved: 150 ms where the moving version had none of its own.
        public static let reducedFade = Curve(easeOut, 0.15)

        /// The picture's entrance (M6, M7): a cover of the background colour over it fades away; the picture itself
        /// never scales or fades.
        public static let coverDelay: Double = 0.04
        /// How dark the last frame goes: 20 % while a link reconnects (it reads as paused, the document stays
        /// legible), 55 % under a failure card (the card must dominate).
        public static let reconnectDim: Double = 0.20
        public static let failureDim: Double = 0.55
    }

    public static let cardRadius: CGFloat = 14
    public static let controlRadius: CGFloat = 10
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  opacity: 1)
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}

public enum FontLoader {
    private static let log = Logger(subsystem: "ai.ronar.nitido", category: "fonts")

    /// Registers the bundled OFL fonts for this process. Safe to call more than once.
    public static func registerBundledFonts() {
        guard let dir = fontsDirectory() else {
            log.error("Bundled fonts not found; the wordmark falls back to the system font")
            return
        }
        for name in ["CormorantGaramond-Italic.ttf", "Marcellus-Regular.ttf"] {
            let url = dir.appendingPathComponent(name)
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                let cfError = error?.takeRetainedValue()
                if let cfError, CFErrorGetCode(cfError) == CTFontManagerError.alreadyRegistered.rawValue {
                    continue
                }
                let detail = cfError.map { CFErrorCopyDescription($0) as String } ?? "unknown error"
                log.error("Could not register \(name, privacy: .public): \(detail, privacy: .public)")
            }
        }
    }

    /// In the signed app the resource bundle sits in Contents/Resources, where the
    /// SwiftPM generated `Bundle.module` does not look (it would fall back to the
    /// absolute .build path and crash on any other Mac). `swift run` and tests keep
    /// the bundle next to the executable, which `Bundle.module` finds.
    private static func fontsDirectory() -> URL? {
        if let resources = Bundle.main.resourceURL {
            let dir = resources.appendingPathComponent("nitido_NitidoUI.bundle/Fonts", isDirectory: true)
            if FileManager.default.fileExists(atPath: dir.path) { return dir }
        }
        return Bundle.module.url(forResource: "Fonts", withExtension: nil)
    }
}
