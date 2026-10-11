import XCTest
import AppKit
@testable import NitidoUI

final class FitTests: XCTestCase {
    func testContentThatFitsStaysExactlyOneToOne() {
        let natural = CGSize(width: 1352.5, height: 848)
        XCTAssertEqual(Fit.factor(natural: natural, limit: CGSize(width: 1400, height: 900)), 1)
        XCTAssertEqual(Fit.size(natural: natural, limit: CGSize(width: 1400, height: 900)), natural)
    }

    func testNeverScalesUp() {
        XCTAssertEqual(Fit.size(natural: CGSize(width: 300, height: 200), limit: CGSize(width: 3000, height: 2000)),
                       CGSize(width: 300, height: 200))
    }

    func testLargerContentScalesDownByTheTighterSide() {
        // The reviewer's case: 2704x1696 px @2x on a 1352x878 pt screen, minus 40 x 120 pt for chrome.
        let natural = CGSize(width: 1352, height: 848)
        let limit = CGSize(width: 1352 - 40, height: 878 - 120)
        let f = Fit.factor(natural: natural, limit: limit)
        XCTAssertEqual(f, 758.0 / 848.0, accuracy: 1e-9)
        let size = Fit.size(natural: natural, limit: limit)
        XCTAssertLessThanOrEqual(size.width, limit.width)
        XCTAssertLessThanOrEqual(size.height, limit.height)
        XCTAssertEqual(size.height, 758)
        XCTAssertEqual(size.width, (1352 * f).rounded(.down))
    }

    /// Spec 17: a picture scaled down says its scale in the strip; at 1:1 it says nothing more.
    func testTheResolutionLabelSaysTheScaleOnlyWhenScaledDown() {
        XCTAssertEqual(Fit.resolutionLabel(pixelSize: .zero, scale: 2, factor: 1), "·")
        XCTAssertEqual(Fit.resolutionLabel(pixelSize: CGSize(width: 3024, height: 1890), scale: 2, factor: 1), "3024×1890 @2x")
        XCTAssertEqual(Fit.resolutionLabel(pixelSize: CGSize(width: 5120, height: 2880), scale: 2, factor: 0.5), "5120×2880 @2x · 50%")
        XCTAssertEqual(Fit.resolutionLabel(pixelSize: CGSize(width: 320, height: 180), scale: 1, factor: 80.0 / 90.0), "320×180 @1x · 89%")
    }

    func testFrameInsideStaysPut() {
        let visible = CGRect(x: 0, y: 0, width: 1352, height: 853)
        let frame = CGRect(x: 100, y: 100, width: 560, height: 392)
        XCTAssertEqual(Fit.constrained(frame, in: visible), frame)
    }

    func testFrameLeftOfTheScreenComesBack() {
        // The reviewer's case: Welcome landed at x = -927 after shrinking from a large share.
        let visible = CGRect(x: 0, y: 0, width: 1352, height: 853)
        let frame = CGRect(x: -927, y: 300, width: 560, height: 392)
        XCTAssertEqual(Fit.constrained(frame, in: visible), CGRect(x: 0, y: 300, width: 560, height: 392))
    }

    func testFrameBelowTheVisibleAreaMovesUp() {
        let visible = CGRect(x: 0, y: 25, width: 1352, height: 853)
        let frame = CGRect(x: 396, y: -36, width: 1352 - 400, height: 700)
        let fitted = Fit.constrained(frame, in: visible)
        XCTAssertEqual(fitted.minY, 25)
        XCTAssertEqual(fitted.size, frame.size)
    }

    func testFrameLargerThanTheScreenKeepsItsTitleBarVisible() {
        let visible = CGRect(x: 0, y: 25, width: 1352, height: 853)
        let frame = CGRect(x: 396, y: 29, width: 1600, height: 1000)
        let fitted = Fit.constrained(frame, in: visible)
        XCTAssertEqual(fitted.minX, 0)
        XCTAssertEqual(fitted.maxY, visible.maxY)
    }

    /// The Share and View windows' picture area: the picture to the whole point, at least 480 by 260 pt, so the pairing
    /// and loop panels and a failure card fit beside a tiny picture; a picture smaller than that sits centred, at whole
    /// points, and one at least that large sits at the top left, a half-point one included.
    func testThePictureAreaHasAMinimumAndCentresASmallPicture() {
        XCTAssertEqual(Fit.area(for: CGSize(width: 100, height: 50)), CGSize(width: 480, height: 260))
        XCTAssertEqual(Fit.origin(of: CGSize(width: 100, height: 50), in: CGSize(width: 480, height: 260)), CGPoint(x: 190, y: 105))
        XCTAssertEqual(Fit.area(for: CGSize(width: 500.5, height: 400.5)), CGSize(width: 501, height: 401))
        XCTAssertEqual(Fit.origin(of: CGSize(width: 500.5, height: 400.5), in: CGSize(width: 501, height: 401)), .zero)
        XCTAssertEqual(Fit.origin(of: CGSize(width: 100.5, height: 50.5), in: CGSize(width: 480, height: 260)), CGPoint(x: 189, y: 104))
        XCTAssertEqual(Fit.area(for: CGSize(width: 1000, height: 100)), CGSize(width: 1000, height: 260), "each side on its own")
    }
}

final class KeepWindowOnScreenTests: XCTestCase {
    /// A resize that leaves the window off the left edge (as after shrinking back to Welcome) is pulled back. The keeper
    /// is given the visible frame of a 14-inch MacBook Pro's screen: off every screen, the window would otherwise be
    /// pulled onto the main one, and with a second display attached that is not always the screen it started on.
    @MainActor
    func testResizeOffTheLeftEdgeIsPulledBackOnScreen() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 720, height: 524),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let keeper = WindowKeeperView()
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 950)
        keeper.visibleFrame = { _ in visible }
        window.contentView = keeper

        window.setFrame(NSRect(x: visible.minX - 927, y: visible.minY + 40, width: 560, height: 392), display: false)

        XCTAssertEqual(window.frame.size, NSSize(width: 560, height: 392))
        XCTAssertTrue(visible.contains(window.frame), "window left at \(window.frame) outside \(visible)")
    }

    /// A resize that pushes the bottom below the visible area (a large share) moves the window up, not smaller.
    @MainActor
    func testGrowingPastTheBottomMovesTheWindowUp() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 560, height: 392),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = WindowKeeperView()
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { throw XCTSkip("no screen") }
        let size = NSSize(width: min(1000, visible.width - 40), height: min(700, visible.height - 20))

        window.setFrame(NSRect(origin: NSPoint(x: visible.minX + 10, y: visible.minY - 200), size: size), display: false)

        XCTAssertEqual(window.frame.size, size)
        XCTAssertTrue(visible.contains(window.frame), "window left at \(window.frame) outside \(visible)")
    }
}
