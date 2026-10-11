import XCTest
import AppKit
import Network
import NitidoCore
@testable import NitidoCapture
@testable import NitidoLink
@testable import NitidoUI

/// Stands in for CaptureSession: the test emits the picker's answer and the capture's events.
@MainActor
private final class PickerSource: CaptureSource {
    let frames: AsyncStream<CapturedFrame>
    let events: AsyncStream<CaptureEvent>
    private let eventOut: AsyncStream<CaptureEvent>.Continuation
    init() {
        (frames, _) = AsyncStream<CapturedFrame>.makeStream()
        (events, eventOut) = AsyncStream<CaptureEvent>.makeStream()
    }
    func presentPicker(excludingWindowIDs: [CGWindowID]) {}
    func stop() async {}
    func emit(_ event: CaptureEvent) { eventOut.yield(event) }
}

/// Every source the app's shares made, newest last: each session gets a fresh one, as in the app.
@MainActor
private final class PickerSources {
    private(set) var made: [PickerSource] = []
    func make() -> any CaptureSource { let source = PickerSource(); made.append(source); return source }
}

/// How many times the app quit.
@MainActor
private final class Quits { var count = 0 }

/// Each time the app brought its window back from the Dock, whether the stop question was up already.
@MainActor
private final class Reveals {
    weak var app: AppModel?
    var questionUp: [Bool] = []
    func reveal() { questionUp.append(app?.confirmStop ?? true) }
}

private struct TimedOut: Error {}

final class AppModelTests: XCTestCase {
    @MainActor
    private func drain() async { for _ in 0..<50 { await Task.yield() } }

    @MainActor
    private func waitUntil(_ what: String, timeout: Double = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { XCTFail("timed out waiting until \(what)"); throw TimedOut() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// An app whose shares capture from `sources`, whose viewer browses nothing (the test says where the sharer is) and
    /// whose quits `quits` counts.
    @MainActor
    private func app(_ sources: PickerSources, quits: Quits = Quits()) -> AppModel {
        AppModel(makeShare: { ShareModel(makeSource: sources.make, screenRecordingGranted: { true }) },
                 makeView: { ViewModel(startingDiscovery: false) }, terminate: { quits.count += 1 })
    }

    /// A share outside the app, capturing and listening, for the app's viewer to pair with over loopback.
    @MainActor
    private func otherMac() async throws -> (ShareModel, Peer) {
        let source = PickerSource()
        let share = ShareModel(makeSource: { source }, screenRecordingGranted: { true })
        share.start(excludingWindowIDs: [])
        await drain()
        source.emit(.started(pixelWidth: 320, pixelHeight: 180, scale: 2))
        try await waitUntil("the other Mac listens") { share.listeningPort != nil }
        return (share, Peer(id: "loopback", name: share.name, keyName: share.name,
                            endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: share.listeningPort!)!)))
    }

    /// Connected as a viewer, ⌘N to share back, then the system picker cancelled, first pick and after Retry: only the
    /// share goes. The viewer keeps its link and the window goes back to the View screen, without the "Disconnect?"
    /// that Esc would ask, and the Mac being watched does not see this one leave.
    @MainActor
    func testCancellingThePickerWhileViewingDropsOnlyTheShare() async throws {
        let (other, peer) = try await otherMac()
        let sources = PickerSources()
        let app = app(sources)
        app.startView()
        let viewer = try XCTUnwrap(app.view)
        viewer.select(peer); viewer.code = other.code; viewer.connect()
        try await waitUntil("the viewer is connected") { viewer.state == .connected && other.isSending }

        app.startShare()
        XCTAssertEqual(app.screen, .share)
        await drain()
        sources.made.last?.emit(.cancelled)
        try await waitUntil("the share goes") { app.share == nil }
        XCTAssertEqual(app.screen, .view, "back to where the person came from")
        XCTAssertTrue(app.view === viewer)
        XCTAssertFalse(app.confirmStop, "nothing to confirm: only the share was being picked")
        XCTAssertEqual(viewer.state, .connected)

        // After Retry: the capture failed, Retry opens the picker again, and that one is cancelled.
        app.startShare()
        await drain()
        sources.made.last?.emit(.started(pixelWidth: 320, pixelHeight: 180, scale: 2))
        try await waitUntil("the share captures") { app.share?.state == .capturing }
        sources.made.last?.emit(.failed(CaptureFailure(reason: .other, detail: "the stream stopped")))
        try await waitUntil("the share failed") { if case .failed = app.share?.state { true } else { false } }
        app.share?.retry()
        await drain()
        XCTAssertEqual(app.share?.state, .picking)
        sources.made.last?.emit(.cancelled)
        try await waitUntil("the share goes") { app.share == nil }
        XCTAssertEqual(app.screen, .view)
        XCTAssertEqual(viewer.state, .connected, "the viewer kept its link")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(other.isSending, "the Mac being watched never saw this one leave")
        XCTAssertEqual(other.viewerName, viewer.name)

        await app.stop()
        await other.stop()
    }

    /// Connected as a viewer, ⌘N to share back, then Esc (or the File menu's Esc item, titled Cancel Sharing there) on the
    /// Share screen while the picker is up, after a capture failure, and after Retry: Esc does what the picker's Cancel
    /// does. Only the share goes, back to the View screen, with no "Disconnect?", and the Mac being watched never sees
    /// this one leave.
    @MainActor
    func testEscapeOnThePickerOrAFailureWhileViewingDropsOnlyTheShare() async throws {
        let (other, peer) = try await otherMac()
        let sources = PickerSources()
        let app = app(sources)
        app.startView()
        let viewer = try XCTUnwrap(app.view)
        viewer.select(peer); viewer.code = other.code; viewer.connect()
        try await waitUntil("the viewer is connected") { viewer.state == .connected && other.isSending }

        /// Esc on the Share screen: the share goes alone, and the viewer stays as it was.
        func escapeDropsOnlyTheShare(_ when: String) async throws {
            XCTAssertEqual(app.screen, .share, when)
            XCTAssertEqual(app.menu.stopTitle, "Cancel Sharing", "the menu item says what Esc does \(when)")
            app.escape()
            XCTAssertFalse(app.confirmStop, "no \"Disconnect?\" \(when): only the share was being picked")
            try await waitUntil("the share goes \(when)") { app.share == nil }
            XCTAssertEqual(app.screen, .view, "back to where the person came from \(when)")
            XCTAssertTrue(app.view === viewer, when)
            XCTAssertEqual(viewer.state, .connected, "the viewer kept its link \(when)")
        }

        // While the picker is up.
        app.startShare()
        await drain()
        XCTAssertEqual(app.share?.state, .picking)
        try await escapeDropsOnlyTheShare("while picking")

        // After a capture failure: the failure card, with Retry.
        app.startShare()
        await drain()
        sources.made.last?.emit(.started(pixelWidth: 320, pixelHeight: 180, scale: 2))
        try await waitUntil("the share captures") { app.share?.state == .capturing }
        sources.made.last?.emit(.failed(CaptureFailure(reason: .other, detail: "the stream stopped")))
        try await waitUntil("the share failed") { if case .failed = app.share?.state { true } else { false } }
        try await escapeDropsOnlyTheShare("after a failure")

        // After Retry: the picker is up again.
        app.startShare()
        await drain()
        sources.made.last?.emit(.failed(CaptureFailure(reason: .other, detail: "the stream could not start")))
        try await waitUntil("the share failed") { if case .failed = app.share?.state { true } else { false } }
        app.share?.retry()
        await drain()
        XCTAssertEqual(app.share?.state, .picking)
        try await escapeDropsOnlyTheShare("after Retry")

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(viewer.state, .connected)
        XCTAssertTrue(other.isSending, "the Mac being watched never saw this one leave")
        XCTAssertEqual(other.viewerName, viewer.name)

        await app.stop()
        await other.stop()
    }

    /// With a viewer that is only looking for Macs, a cancelled picker also goes back to View; with none, to Welcome.
    @MainActor
    func testACancelledPickerGoesBackToWelcomeOrToTheViewScreen() async throws {
        let sources = PickerSources()
        let app = app(sources)
        app.startShare()
        await drain()
        sources.made.last?.emit(.cancelled)
        try await waitUntil("the share goes") { app.share == nil }
        XCTAssertEqual(app.screen, .welcome)

        app.startView()
        let viewer = app.view
        app.startShare()
        await drain()
        sources.made.last?.emit(.cancelled)
        try await waitUntil("the share goes") { app.share == nil }
        XCTAssertEqual(app.screen, .view)
        XCTAssertTrue(app.view === viewer)
    }

    /// Esc on the code screen goes back to the list, as its Back button does (and the menu item, titled Back, says), even
    /// with a share running behind the View screen; Esc on a failure before any picture goes back to the list too. Only
    /// Esc on the list leaves View.
    @MainActor
    func testEscapeOnTheCodeScreenGoesBackToTheList() async throws {
        let sources = PickerSources()
        let app = app(sources)
        app.startView()
        let viewer = try XCTUnwrap(app.view)
        let peer = Peer(id: "mac", name: "Mac", keyName: "Mac", endpoint: .hostPort(host: "127.0.0.1", port: 9))
        viewer.select(peer)
        XCTAssertEqual(app.menu.stopTitle, "Back")
        app.escape()
        await drain()
        XCTAssertEqual(viewer.state, .browsing, "back to the list")
        XCTAssertEqual(app.screen, .view)
        XCTAssertFalse(app.confirmStop)

        // With a share running behind the View screen.
        app.startShare()
        await drain()
        sources.made.last?.emit(.started(pixelWidth: 320, pixelHeight: 180, scale: 2))
        try await waitUntil("the share captures") { app.share?.state == .capturing }
        app.startView()
        viewer.select(peer)
        XCTAssertEqual(app.menu.stopTitle, "Back", "the menu item says what Esc does there")
        app.escape()
        await drain()
        XCTAssertFalse(app.confirmStop, "no question about the share behind: Esc is Back here")
        XCTAssertEqual(viewer.state, .browsing)
        XCTAssertEqual(app.share?.state, .capturing)
        XCTAssertEqual(app.menu.stopTitle, "Stop Sharing", "on the list, Esc stops the share behind it")
        app.escape()
        XCTAssertTrue(app.confirmStop, "and asks first")
        app.cancelledStop(); app.confirmStop = false

        // A failure before any picture: the one to the closed port.
        viewer.select(peer); viewer.code = "1234"; viewer.connect()
        try await waitUntil("the attempt fails") { if case .failed = viewer.state { true } else { false } }
        app.escape()
        await drain()
        XCTAssertEqual(viewer.state, .browsing)
        await app.stop()
    }

    /// ⌘Q, ⌘W and the close button (`requestQuit`): with nothing live the app quits at once; with a viewer connected it
    /// asks the same question as Esc and quits only after Stop, once the session has stopped; Cancel quits nothing, and
    /// an Esc question after it never quits.
    @MainActor
    func testAQuitAsksFirstWhileSomethingIsLive() async throws {
        let sources = PickerSources(), quits = Quits()
        let app = app(sources, quits: quits)
        app.requestQuit()
        XCTAssertEqual(quits.count, 1, "nothing live: quit at once")

        let (other, peer) = try await otherMac()
        app.startView()
        let viewer = try XCTUnwrap(app.view)
        viewer.select(peer); viewer.code = other.code; viewer.connect()
        try await waitUntil("the viewer is connected") { viewer.state == .connected && other.isSending }
        app.requestQuit()
        XCTAssertTrue(app.confirmStop, "asks first")
        XCTAssertEqual(app.stopQuestion, "Disconnect?")
        XCTAssertEqual(quits.count, 1, "and quits nothing yet")
        app.cancelledStop(); app.confirmStop = false
        XCTAssertEqual(viewer.state, .connected, "Cancel stops nothing")
        app.escape()
        XCTAssertTrue(app.confirmStop)
        app.confirmedStop(); app.confirmStop = false
        try await waitUntil("Esc's Stop disconnects") { app.view == nil }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(quits.count, 1, "an Esc question never quits")

        app.startView()
        let again = try XCTUnwrap(app.view)
        again.select(peer); again.code = other.code; again.connect()
        try await waitUntil("connected again") { again.state == .connected && other.isSending }
        app.requestQuit()
        app.confirmedStop(); app.confirmStop = false
        try await waitUntil("the app quits once the session has stopped") { quits.count == 2 }
        XCTAssertNil(app.view)
        try await waitUntil("the other Mac heard the goodbye") { !other.isSending && other.viewerName == nil }
        await other.stop()
    }

    /// ⌘Q while the only window is in the Dock: the question is a sheet on that window, which would not show until the
    /// window came back, so ⌘Q seemed to do nothing. The window comes back first, then the question; the same for the File
    /// menu's Esc item, which works with no window key. With nothing live the app quits and brings nothing back.
    @MainActor
    func testTheQuestionBringsAMinimizedWindowBackFirst() async throws {
        let sources = PickerSources(), quits = Quits(), reveals = Reveals()
        let app = AppModel(makeShare: { ShareModel(makeSource: sources.make, screenRecordingGranted: { true }) },
                           makeView: { ViewModel(startingDiscovery: false) }, terminate: { quits.count += 1 },
                           revealWindow: { reveals.reveal() })
        reveals.app = app
        app.requestQuit()
        XCTAssertEqual(quits.count, 1, "nothing live: quit at once")
        XCTAssertEqual(reveals.questionUp, [], "and nothing to bring back")

        app.startShare()
        await drain()
        sources.made.last?.emit(.started(pixelWidth: 320, pixelHeight: 180, scale: 2))
        try await waitUntil("the share captures") { app.share?.state == .capturing }
        app.requestQuit()
        XCTAssertTrue(app.confirmStop, "asks first")
        XCTAssertEqual(reveals.questionUp, [false], "the window came back before the question")
        app.cancelledStop(); app.confirmStop = false
        app.escape()
        XCTAssertTrue(app.confirmStop)
        XCTAssertEqual(reveals.questionUp, [false, false], "Esc's question too")
        app.cancelledStop(); app.confirmStop = false
        XCTAssertEqual(quits.count, 1)
        await app.stop()
    }

    /// The close button, and ⌘W, which presses it (`NSWindow.performClose`), go through `requestQuit`.
    @MainActor
    func testTheCloseButtonAndCommandWGoThroughTheQuestion() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var asked = 0
        let guardView = CloseButtonQuitsView { asked += 1 }
        window.contentView?.addSubview(guardView)
        window.orderFront(nil)
        XCTAssertTrue(window.standardWindowButton(.closeButton)?.target === guardView)
        window.performClose(nil)
        XCTAssertEqual(asked, 1)
        window.standardWindowButton(.closeButton)?.performClick(nil)
        XCTAssertEqual(asked, 2)
        XCTAssertTrue(window.isVisible, "the window does not close by itself: the question decides")
        window.orderOut(nil)
    }

    /// Quitting with a share and a view both live: both goodbyes go out together, and each other side hears its own. The
    /// viewer's goodbye is slow here, as over a link that waits for its one-second fallback: the share's viewer still
    /// hears the share end at once, long before that goodbye is done. Said one after the other, the share's bye would wait
    /// behind it (on loopback each bye takes milliseconds, so without the slow one the order could not be told).
    @MainActor
    func testStopEndsAShareAndAViewTogetherAndBothSidesHearBye() async throws {
        let (other, peer) = try await otherMac()
        let sources = PickerSources()
        let app = app(sources)
        app.startView()
        let viewer = try XCTUnwrap(app.view)
        viewer.select(peer); viewer.code = other.code; viewer.connect()
        try await waitUntil("the viewer is connected") { viewer.state == .connected && other.isSending }
        app.startShare()
        await drain()
        sources.made.last?.emit(.started(pixelWidth: 320, pixelHeight: 180, scale: 2))
        let share = try XCTUnwrap(app.share)
        try await waitUntil("the app's share listens") { share.listeningPort != nil }
        let watcher = ViewModel(startingDiscovery: false)
        watcher.select(Peer(id: "app", name: share.name, keyName: share.name,
                            endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: share.listeningPort!)!)))
        watcher.code = share.code; watcher.connect()
        try await waitUntil("the app's share has a viewer") { watcher.state == .connected && share.isSending }

        viewer.slowGoodbyeForTesting = .milliseconds(1500)
        let started = Date()
        let stopping = Task { await app.stop(); return Date().timeIntervalSince(started) }
        try await waitUntil("the app's viewer heard the share end while the viewer's goodbye is still under way", timeout: 1) {
            if case .failed("The sharer ended the session.", _) = watcher.state { true } else { false }
        }
        let took = await stopping.value
        XCTAssertGreaterThanOrEqual(took, 1.5, "the viewer's goodbye was slow")
        XCTAssertLessThan(took, 2.5, "the stop took as long as the slower goodbye, not the two added")
        try await waitUntil("the other Mac heard the viewer leave") { !other.isSending && other.viewerName == nil }
        watcher.disconnect()
        await other.stop()
    }
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
        XCTAssertEqual(AppModel.stopMessage(sharing: true, viewing: true, viewer: "Mac Studio de Ana", sharer: ""),
                       "Mac Studio de Ana will see that you stopped sharing, and the other Mac will see that you disconnected.",
                       "no capital mid-sentence")
        XCTAssertEqual(AppModel.stopMessage(sharing: false, viewing: true, viewer: nil, sharer: ""),
                       "The other Mac will see that you disconnected.")
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
        let pickingOverAView = AppModel.menu(screen: .share, sharing: false, viewing: true, shareBack: true)
        XCTAssertEqual(pickingOverAView, .init(stopTitle: "Cancel Sharing", canStop: true, canToggleTelemetry: true, canInk: false, canToggleLoop: false),
                       "Esc on the picker or a failure, with a viewer open, drops the share alone and goes back to View")
        XCTAssertEqual(AppModel.menu(screen: .share, sharing: false, viewing: false, shareBack: true).stopTitle, "Cancel Sharing",
                       "with a viewer only looking for Macs too")
    }
}
