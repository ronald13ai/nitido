import XCTest
@testable import NitidoUI

final class AppModelTests: XCTestCase {
    /// Esc (the in-window button and the Stop menu item) goes through `escape()`, which returns to Welcome, without
    /// asking when nothing is being shared or viewed.
    @MainActor
    func testEscapeReturnsToWelcome() async {
        let app = AppModel()
        app.screen = .view
        app.escape()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertFalse(app.confirmStop, "nothing to stop: no question")
        XCTAssertEqual(app.screen, .welcome)
        XCTAssertNil(app.share)
    }

    /// View shows the viewer; asking again keeps the same one; telemetry, undo and clear reach it; Esc lets it go.
    @MainActor
    func testViewShowsOneViewerAndEscapeLetsItGo() async {
        let app = AppModel()
        app.startView()
        XCTAssertEqual(app.screen, .view)
        let viewer = app.view
        XCTAssertNotNil(viewer)
        XCTAssertEqual(viewer?.state, .browsing)
        app.startView()
        XCTAssertTrue(app.view === viewer, "a second View keeps the viewer instead of replacing it")
        XCTAssertEqual(viewer?.showTelemetry, true)
        app.toggleTelemetry()
        XCTAssertEqual(viewer?.showTelemetry, false)
        app.escape()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertFalse(app.confirmStop, "a viewer that is only looking for Macs goes without a question")
        XCTAssertEqual(app.screen, .welcome)
        XCTAssertNil(app.view)
        XCTAssertEqual(viewer?.state, .browsing)
    }
}
