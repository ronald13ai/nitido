import XCTest
import AppKit
import SwiftUI
import Network
import NitidoLink
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

    /// The code field takes typing as soon as it appears after a Mac is picked from the list: no click first, or the
    /// first digits typed would go nowhere.
    @MainActor
    func testTheCodeFieldTakesTypingAsSoonAsItAppears() async throws {
        let model = ViewModel(startingDiscovery: false)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 560, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = NSHostingController(rootView: ViewView(model: model))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentViewController = nil }
        try await Task.sleep(for: .milliseconds(200))
        model.select(Peer(id: "mac", name: "Mac", keyName: "Mac", endpoint: .hostPort(host: "127.0.0.1", port: 1)))
        var waits = 0
        while !(window.firstResponder is NSText), waits < 50 { try await Task.sleep(for: .milliseconds(20)); waits += 1 }
        XCTAssertTrue(window.firstResponder is NSText, "the code field is focused: \(String(describing: window.firstResponder))")
    }

    /// The sharer chip's dot is inactive while reconnecting, as the sharer's own panel shows its viewer.
    @MainActor
    func testTheSharerChipsDotIsInactiveWhileReconnecting() {
        let mac = Peer(id: "mac", name: "Mac", keyName: "Mac", endpoint: .hostPort(host: "127.0.0.1", port: 1))
        XCTAssertEqual(ViewView.sharerDot(.connected), Theme.Colors.success)
        XCTAssertEqual(ViewView.sharerDot(.reconnecting(mac, attempt: 2)), Theme.Colors.muted)
    }
}
