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

    /// Quitting with nothing live quits at once.
    @MainActor
    func testQuitWithNothingLiveQuitsAtOnce() {
        let app = AppModel()
        var quits = 0
        XCTAssertTrue(app.shouldQuitNow { quits += 1 })
        XCTAssertEqual(quits, 0, "nothing to wait for: the app answers at once instead")
    }

    /// Esc's question names what it stops (`requestStop`): a share that keeps running behind the View screen is
    /// stopped by the same confirmation, so the title says so.
    func testTheStopQuestionNamesWhatStops() {
        XCTAssertEqual(AppModel.stopWording(sharing: true, viewing: false).question, "Stop sharing?")
        XCTAssertEqual(AppModel.stopWording(sharing: true, viewing: false).action, "Stop")
        XCTAssertEqual(AppModel.stopWording(sharing: false, viewing: true).question, "Disconnect?")
        XCTAssertEqual(AppModel.stopWording(sharing: false, viewing: true).action, "Disconnect")
        XCTAssertEqual(AppModel.stopWording(sharing: true, viewing: true).question, "Stop sharing and disconnect?")
        XCTAssertEqual(AppModel.stopWording(sharing: true, viewing: true).action, "Stop and Disconnect")
    }
}
