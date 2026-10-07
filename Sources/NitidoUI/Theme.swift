import SwiftUI
import AppKit
import CoreText
import os

public enum Theme {
    public enum Colors {
        public static let background = Color(hex: 0x08090c)
        public static let surface = Color(hex: 0x0e1015)
        public static let hairline = Color(hex: 0x2b2e38)
        public static let muted = Color(hex: 0x3a3e4a)
        public static let text = Color(hex: 0xf2f3f5)
        public static let gold = Color(hex: 0xc9a86a)
        public static let goldHighlight = Color(hex: 0xd8ba7e)
        public static let cream = Color(hex: 0xf3e3ba)
        public static let success = Color(hex: 0x62c37e)
        public static let softRed = Color(hex: 0xe08f8f)
        public static let goldGradient = LinearGradient(
            colors: [gold, goldHighlight], startPoint: .topLeading, endPoint: .bottomTrailing)
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
    }

    public enum Motion {
        /// Strong ease-out for entrances.
        public static let enter = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.22)
        public static let exit = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.14)
        public static let press = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.12)
        public static let connect = Animation.spring(duration: 0.5, bounce: 0.2)
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
