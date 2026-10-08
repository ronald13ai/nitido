import XCTest
import SwiftUI
import AppKit
@testable import NitidoUI

/// Secondary text (the Welcome subtitle, small-caps captions, the strip's labels and units) must be readable on the
/// dark background and surface: WCAG asks 4.5:1 for body text. `muted` (#3a3e4a) gave about 1.9:1, so it is kept for
/// hairlines and inactive states, and text uses `secondaryText`.
final class ThemeContrastTests: XCTestCase {
    /// WCAG relative luminance of an sRGB colour.
    private func luminance(_ color: Color) throws -> Double {
        let ns = try XCTUnwrap(NSColor(color).usingColorSpace(.sRGB))
        func linear(_ c: CGFloat) -> Double {
            let v = Double(c)
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(ns.redComponent) + 0.7152 * linear(ns.greenComponent) + 0.0722 * linear(ns.blueComponent)
    }

    private func contrast(_ a: Color, _ b: Color) throws -> Double {
        let la = try luminance(a), lb = try luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    func testSecondaryTextIsReadableOnTheBackgroundAndTheSurface() throws {
        XCTAssertGreaterThanOrEqual(try contrast(Theme.Colors.secondaryText, Theme.Colors.background), 4.5)
        XCTAssertGreaterThanOrEqual(try contrast(Theme.Colors.secondaryText, Theme.Colors.surface), 4.5)
        XCTAssertLessThan(try contrast(Theme.Colors.muted, Theme.Colors.background), 4.5, "muted is not for text")
    }
}
