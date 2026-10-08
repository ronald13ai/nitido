import XCTest
@testable import NitidoUI

/// Spec 12 and 13: only a wrong code may say "Wrong code". The key is derived from the code's bytes, so the right code
/// typed in another script's digits (a Japanese IME's full-width digits, an Arabic or Persian keyboard) must reach it
/// as ASCII digits, and nothing that is not a decimal digit may reach it at all.
final class CodeEntryTests: XCTestCase {
    func testEveryScriptsDecimalDigitsBecomeASCIIDigits() {
        XCTAssertEqual(ViewModel.normalizedCode("1234"), "1234")
        XCTAssertEqual(ViewModel.normalizedCode("１２３４"), "1234", "full-width")
        XCTAssertEqual(ViewModel.normalizedCode("١٢٣٤"), "1234", "Arabic-Indic")
        XCTAssertEqual(ViewModel.normalizedCode("۱۲۳۴"), "1234", "Persian")
        XCTAssertEqual(ViewModel.normalizedCode("१२३४"), "1234", "Devanagari")
    }

    func testAnythingButADecimalDigitIsDroppedAndFourAreKept() {
        XCTAssertEqual(ViewModel.normalizedCode("²³½¼"), "", "superscripts and fractions are numbers, not digits")
        XCTAssertEqual(ViewModel.normalizedCode("12a345"), "1234")
        XCTAssertEqual(ViewModel.normalizedCode(" 9 8-7·6 "), "9876")
        XCTAssertEqual(ViewModel.normalizedCode("Ⅻ"), "", "a Roman numeral")
        XCTAssertEqual(ViewModel.normalizedCode(""), "")
    }
}
