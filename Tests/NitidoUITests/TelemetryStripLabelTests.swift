import XCTest
import CoreText
@testable import NitidoUI

/// Small-caps labels are set in the bundled Marcellus, uppercased. A character the font lacks falls back to another
/// font at another weight and baseline inside an 8 or 9 pt label (Marcellus has no U+2192, the arrow), so every such
/// label must be fully covered by it.
final class TelemetryStripLabelTests: XCTestCase {
    @MainActor
    func testEveryMarcellusLabelHasItsGlyphs() throws {
        FontLoader.registerBundledFonts()
        let font = CTFontCreateWithName("Marcellus-Regular" as CFString, 9, nil)
        XCTAssertEqual(CTFontCopyPostScriptName(font) as String, "Marcellus-Regular", "the bundled font, not a fallback")
        let labels = TelemetryStrip.fixedLabels + [ShareView.latencyLabel, ViewView.latencyLabel]
            + ["code", "Macs sharing on this network", "Enter the 4-digit code shown on that Mac", "Quality", "Raw",
               "HEVC · 60 Mbps", "H.264 · 60 Mbps"]
        for label in labels.map({ $0.uppercased() }) {
            let characters = Array(label.utf16)
            var glyphs = [CGGlyph](repeating: 0, count: characters.count)
            let covered = CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count)
            let missing = zip(label.unicodeScalars, glyphs).filter { $0.1 == 0 }.map { String($0.0) }
            XCTAssertTrue(covered, "Marcellus has no glyph for \(missing) in \"\(label)\"")
        }
    }
}
