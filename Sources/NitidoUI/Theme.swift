import SwiftUI
import AppKit
import CoreText
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

    public enum Motion {
        /// Strong ease-out for entrances.
        public static let enter = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.22)
        public static let press = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.12)
        /// Hover answers as fast as a press, on the same curve.
        public static let hover = press
        /// Exits are faster than entrances: a plain ease-out over 120 ms.
        public static let exit = Animation.easeOut(duration: 0.12)
        public static let connect = Animation.spring(duration: 0.5, bounce: 0.2)
        /// After the connect ring has drawn, it eases down to a hairline: the settle.
        public static let settle = Animation.easeInOut(duration: 0.6)
        public static let stagger: Double = 0.04
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
