import XCTest
import AppKit
import SwiftUI
import Network
import NitidoLink
@testable import NitidoUI

/// The View screen's list and what VoiceOver hears.
final class ViewScreenTests: XCTestCase {
    /// The scroll views under `view`, depth first.
    @MainActor
    private func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap { scrollViews(in: $0) }
    }

    /// Eight Macs sharing: the rows scroll inside the 600 by 400 canvas instead of running off the window, where the
    /// seventh and the eighth could not be seen or picked.
    @MainActor
    func testTheListOfMacsScrollsInsideTheCanvas() async throws {
        _ = NSApplication.shared
        let viewer = ViewModel(startingDiscovery: false)
        viewer.peers = (1...8).map { Peer(id: "\($0)", name: "Mac \($0)", keyName: "Mac \($0)", endpoint: .hostPort(host: "127.0.0.1", port: 9)) }
        let controller = NSHostingController(rootView: ViewView(model: viewer))
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 600, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.contentViewController = nil }
        for _ in 0..<10 { try await Task.sleep(for: .milliseconds(30)); controller.view.layoutSubtreeIfNeeded() }
        XCTAssertEqual(controller.view.fittingSize, ViewView.canvas, "the canvas does not grow with the list")
        let scroll = try XCTUnwrap(scrollViews(in: controller.view).first, "the rows sit in a scroll view")
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(document.frame.height, scroll.contentView.bounds.height, "eight rows overflow, so they scroll")
        XCTAssertGreaterThanOrEqual(document.frame.height, 8 * 48 + 7 * 8, "all eight rows are there")
    }

    /// VoiceOver hears the reconnect and each failure with its card's title; the list and the code say nothing new.
    func testVoiceOverAnnouncesReconnectingAndFailures() {
        let mac = Peer(id: "a", name: "MacBook Pro de Ronald", keyName: "MacBook Pro de Ronald", endpoint: .hostPort(host: "127.0.0.1", port: 9))
        XCTAssertEqual(ViewView.announcement(for: .reconnecting(mac, attempt: 1), failureTitle: ""), "Reconnecting to MacBook Pro de Ronald")
        XCTAssertEqual(ViewView.announcement(for: .reconnecting(mac, attempt: 3), failureTitle: ""), "Reconnecting to MacBook Pro de Ronald",
                       "the same words for every attempt, so it is said once")
        XCTAssertEqual(ViewView.announcement(for: .failed("Disconnected.", mac), failureTitle: "The session ended"),
                       "The session ended. Disconnected.")
        for quiet: ViewModel.State in [.browsing, .enteringCode(mac), .connecting(mac), .connected] {
            XCTAssertNil(ViewView.announcement(for: quiet, failureTitle: ""))
        }
    }

    /// The Screen Recording card says what works: a grant reaches a running app only after it quits and reopens, and a
    /// switch already on belongs to another copy of Nítido.
    func testTheScreenRecordingCardSaysToQuitAndReopenAndWhenTheSwitchIsOnAlready() {
        XCTAssertTrue(ShareView.screenRecordingFix.contains("then quit and reopen Nítido"))
        XCTAssertTrue(ShareView.screenRecordingFix.contains("remove Nítido from the list with the minus button and add it again"))
        XCTAssertFalse(ShareView.screenRecordingFix.contains("Retry"))
    }
}
