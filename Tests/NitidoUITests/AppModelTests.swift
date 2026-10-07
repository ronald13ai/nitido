import XCTest
@testable import NitidoUI

final class AppModelTests: XCTestCase {
    /// Esc (the in-window button and the Stop menu item) goes through `escape()`, which returns to Welcome.
    @MainActor
    func testEscapeReturnsToWelcome() async {
        let app = AppModel()
        app.screen = .view
        app.escape()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(app.screen, .welcome)
        XCTAssertNil(app.share)
    }
}
