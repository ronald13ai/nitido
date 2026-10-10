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

    /// The confirmation's message names who is disconnected and what they will see (spec 11).
    func testTheConfirmationNamesWhoWillSeeIt() {
        XCTAssertEqual(AppModel.stopMessage(sharing: true, viewing: false, viewer: "Mac Studio de Ana", sharer: ""),
                       "Mac Studio de Ana will see that you stopped sharing.")
        XCTAssertEqual(AppModel.stopMessage(sharing: true, viewing: false, viewer: nil, sharer: ""),
                       "The picture closes and the code stops working.")
        XCTAssertEqual(AppModel.stopMessage(sharing: false, viewing: true, viewer: nil, sharer: "MacBook Pro de Ronald"),
                       "MacBook Pro de Ronald will see that you disconnected.")
        XCTAssertEqual(AppModel.stopMessage(sharing: true, viewing: true, viewer: "Mac Studio de Ana", sharer: "Mac mini"),
                       "Mac Studio de Ana will see that you stopped sharing, and Mac mini will see that you disconnected.")
    }

    /// The menu offers what the screen shown can do (spec 9): the Esc item says what it stops, and Undo Stroke, Clear
    /// Ink and Codec Loop are disabled where they would do nothing, or act on a share running behind the View screen.
    func testTheMenuOffersWhatTheScreenShownCanDo() {
        let welcome = AppModel.menu(screen: .welcome, sharing: false, viewing: false)
        XCTAssertEqual(welcome, .init(stopTitle: "Stop", canStop: false, canToggleTelemetry: false, canInk: false, canToggleLoop: false))
        let picking = AppModel.menu(screen: .share, sharing: false, viewing: false)
        XCTAssertEqual(picking, .init(stopTitle: "Stop Sharing", canStop: true, canToggleTelemetry: true, canInk: false, canToggleLoop: false))
        let sharing = AppModel.menu(screen: .share, sharing: true, viewing: false)
        XCTAssertEqual(sharing, .init(stopTitle: "Stop Sharing", canStop: true, canToggleTelemetry: true, canInk: true, canToggleLoop: true))
        let list = AppModel.menu(screen: .view, sharing: false, viewing: false)
        XCTAssertEqual(list, .init(stopTitle: "Back", canStop: true, canToggleTelemetry: true, canInk: false, canToggleLoop: false))
        let viewing = AppModel.menu(screen: .view, sharing: false, viewing: true)
        XCTAssertEqual(viewing, .init(stopTitle: "Disconnect", canStop: true, canToggleTelemetry: true, canInk: true, canToggleLoop: false))
        let both = AppModel.menu(screen: .view, sharing: true, viewing: true)
        XCTAssertEqual(both, .init(stopTitle: "Stop Sharing and Disconnect", canStop: true, canToggleTelemetry: true, canInk: true, canToggleLoop: false),
                       "the share behind the View screen keeps its loop")
        let listOverAShare = AppModel.menu(screen: .view, sharing: true, viewing: false)
        XCTAssertEqual(listOverAShare.stopTitle, "Stop Sharing")
        XCTAssertFalse(listOverAShare.canInk, "no picture shown, so no ink to act on")
    }
}
