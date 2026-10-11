import XCTest
import AppKit
import SwiftUI
import NitidoCapture
@testable import NitidoUI

/// A capture source the test drives by hand: every `.started` is a new pick of another size.
@MainActor
private final class PickSource: CaptureSource {
    let frames = AsyncStream<CapturedFrame> { _ in }
    let events: AsyncStream<CaptureEvent>
    private let out: AsyncStream<CaptureEvent>.Continuation
    init() { (events, out) = AsyncStream<CaptureEvent>.makeStream() }
    func presentPicker(excludingWindowIDs: [CGWindowID]) {}
    func stop() async {}
    func pick(_ width: Int, _ height: Int) { out.yield(.started(pixelWidth: width, pixelHeight: height, scale: 2)) }
}

/// The content's size range as the window sees it: `.windowResizability(.contentSize)` keeps the window between
/// the content's minimum (everything proposed zero) and maximum (everything proposed infinite) size.
@MainActor
private struct SizeRange {
    let min: CGSize, max: CGSize, fitting: CGSize
    init(_ controller: NSHostingController<some View>) {
        min = controller.sizeThatFits(in: .zero)
        max = controller.sizeThatFits(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        fitting = controller.view.fittingSize
    }
}

final class ShareWindowSizeTests: XCTestCase {
    @MainActor
    /// Lets the model handle the event and SwiftUI apply it (the main run loop turns while the test sleeps).
    private func settle(_ view: NSView) async {
        for _ in 0..<10 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        view.layoutSubtreeIfNeeded()
    }

    /// The reviewer's probe: picks that get narrower must make the window narrower. The Share content is exactly
    /// as wide as the picture, to the whole point (minimum, maximum and fitting width), so `.contentSize` fixes
    /// the width the way it already fixes the height, and nothing (the strip's spacer) lets it stay wide or be
    /// dragged wider. 1001 x 801 px is the odd case: 500.5 x 400.5 pt, a window of 501 pt.
    @MainActor
    func testShareContentIsExactlyAsWideAsThePictureForEveryPick() async throws {
        _ = NSApplication.shared
        var source: PickSource?
        let model = ShareModel(makeSource: { let s = PickSource(); source = s; return s }, screenRecordingGranted: { true })
        let controller = NSHostingController(rootView: ShareView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 560, height: 360),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.contentViewController = nil }

        model.start(excludingWindowIDs: [])
        await settle(controller.view)
        XCTAssertEqual(model.state, .picking)
        assertWidth(SizeRange(controller), equals: Fit.area(for: model.fittedPointSize).width, "picking placeholder")

        // Wide, then narrower and narrower, including a pick narrower than the strip's one-row width, and one smaller
        // than the minimum picture area (a 200 by 100 px utility), which sits centred on the background.
        for (w, h) in [(2400, 1600), (1001, 801), (2400, 1600), (700, 500), (300, 200), (200, 100)] {
            source?.pick(w, h)
            await settle(controller.view)
            XCTAssertEqual(model.pixelSize, CGSize(width: w, height: h))
            let range = SizeRange(controller)
            assertWidth(range, equals: Fit.area(for: model.fittedPointSize).width, "pick \(w)x\(h)")
            XCTAssertEqual(range.min.height, range.max.height, accuracy: 0.001, "pick \(w)x\(h): the height is fixed too")
            try assertPictureFillsTheTop(of: window, model: model, label: "pick \(w)x\(h)")
        }

        // Hiding the strip keeps the same width.
        model.showTelemetry = false
        await settle(controller.view)
        assertWidth(SizeRange(controller), equals: Fit.area(for: model.fittedPointSize).width, "strip hidden")
        await model.stop()
    }

    /// With the window at the content's size, the picture sits exactly at the content's top-left corner with
    /// the fitted size: an overlay (the pairing panel) must not push it, and a half-point picture must not be
    /// centered off the pixel grid or have a column cut off. A picture smaller than the minimum area sits centred in it,
    /// at whole points.
    @MainActor
    private func assertPictureFillsTheTop(of window: NSWindow, model: ShareModel, label: String,
                                          file: StaticString = #filePath, line: UInt = #line) throws {
        guard let content = window.contentView else { throw XCTSkip("no content view") }
        let fitting = content.fittingSize
        XCTAssertEqual(fitting.width, fitting.width.rounded(), "\(label): a whole-point window width", file: file, line: line)
        window.setContentSize(fitting)
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(content.bounds.size, fitting, "\(label): the window takes the content's size", file: file, line: line)
        let video = try XCTUnwrap(model.sink.view, "\(label): the video view exists", file: file, line: line)
        let frame = video.convert(video.bounds, to: content)
        let top = content.isFlipped ? frame.minY : content.bounds.height - frame.maxY
        let origin = Fit.origin(of: model.fittedPointSize, in: Fit.area(for: model.fittedPointSize))
        XCTAssertEqual(frame.minX, origin.x, accuracy: 0.001, "\(label): picture x", file: file, line: line)
        XCTAssertEqual(top, origin.y, accuracy: 0.001, "\(label): picture top", file: file, line: line)
        XCTAssertEqual(origin.x, origin.x.rounded(), "\(label): on whole points", file: file, line: line)
        XCTAssertEqual(frame.size.width, model.fittedPointSize.width, accuracy: 0.001, "\(label): picture width", file: file, line: line)
        XCTAssertEqual(frame.size.height, model.fittedPointSize.height, accuracy: 0.001, "\(label): picture height", file: file, line: line)
    }

    @MainActor
    private func assertWidth(_ range: SizeRange, equals width: CGFloat, _ label: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(range.min.width, width, accuracy: 0.001, "\(label): minimum width", file: file, line: line)
        XCTAssertEqual(range.max.width, width, accuracy: 0.001, "\(label): maximum width", file: file, line: line)
        XCTAssertEqual(range.fitting.width, width, accuracy: 0.001, "\(label): fitting width", file: file, line: line)
    }
}

final class StripRowsTests: XCTestCase {
    /// Three 100 x 20 figures and a 50 x 10 sparkline, 10 pt apart, 5 pt of extra room before the sparkline.
    @MainActor
    private func size(offered width: CGFloat?) -> CGSize {
        let rows = StripRows(spacing: 10, rowSpacing: 6, sparklineGap: 5) {
            ForEach(0..<3, id: \.self) { _ in Color.clear.frame(width: 100, height: 20) }
            Color.clear.frame(width: 50, height: 10)
        }
        let controller = NSHostingController(rootView: rows)
        return controller.sizeThatFits(in: CGSize(width: width ?? .greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
    }

    @MainActor
    func testOneRowWhenEverythingFitsAndExactlyTheOfferedWidth() {
        // 100 + 10 + 100 + 10 + 100 + (10 + 5 + 10) + 50 = 395.
        XCTAssertEqual(size(offered: 400), CGSize(width: 400, height: 20))
        XCTAssertEqual(size(offered: 395), CGSize(width: 395, height: 20))
        XCTAssertEqual(size(offered: 1000), CGSize(width: 1000, height: 20), "the strip takes the width it is given")
    }

    @MainActor
    func testWrapsOntoMoreRowsWhenNarrowerInsteadOfGrowingWider() {
        // 300: [100 100] then [100 + sparkline (175)]: two rows.
        XCTAssertEqual(size(offered: 300), CGSize(width: 300, height: 20 + 6 + 20))
        // 120: one figure per row and the sparkline on a row of its own.
        XCTAssertEqual(size(offered: 120), CGSize(width: 120, height: 20 * 3 + 10 + 6 * 3))
    }

    /// The real strip: exactly as wide as offered, one row when wide, taller (wrapped) when narrow.
    @MainActor
    func testTelemetryStripTakesTheOfferedWidthAndWrapsWhenNarrow() {
        func measure(_ width: CGFloat) -> CGSize {
            let strip = TelemetryStrip(snapshot: .empty, resolution: "2048×1280 @2x", codec: "raw", latencyLabel: ShareView.latencyLabel)
            return NSHostingController(rootView: strip.frame(width: width)).sizeThatFits(in: CGSize(width: width, height: 10_000))
        }
        let wide = measure(1200), narrow = measure(350), tiny = measure(150)
        XCTAssertEqual(wide.width, 1200)
        XCTAssertEqual(narrow.width, 350)
        XCTAssertEqual(tiny.width, 150)
        XCTAssertGreaterThan(narrow.height, wide.height, "narrower than one row: the figures wrap")
        XCTAssertGreaterThan(tiny.height, narrow.height)
    }
}

/// Set by an observation's change handler, which may run on any thread.
private final class Fired: @unchecked Sendable {
    var value = false
}

/// The window's 1:1 size follows the display the picture is on, observably: the sink hears it from the view's window
/// (`FrameSink.displayChanged`), so a window dragged to a display of another scale takes its new size even with the
/// strip hidden, when nothing else the view reads changes.
final class DisplayChangeTests: XCTestCase {
    @MainActor
    func testTheShareWindowSizeFollowsTheDisplayThePictureIsOn() async throws {
        var source: PickSource?
        let model = ShareModel(makeSource: { let s = PickSource(); source = s; return s }, screenRecordingGranted: { true })
        model.start(excludingWindowIDs: [])
        for _ in 0..<50 { await Task.yield() }
        source?.pick(3024, 1890)
        for _ in 0..<50 where model.pixelSize == .zero { await Task.yield() }
        XCTAssertEqual(model.pixelSize, CGSize(width: 3024, height: 1890))

        let visible = CGRect(x: 0, y: 0, width: 3000, height: 2000)
        model.sink.displayChanged(scale: 2, visibleFrame: visible)
        XCTAssertEqual(model.fittedPointSize, CGSize(width: 1512, height: 945), "1:1 on a 2x display")

        let fired = Fired()
        withObservationTracking { _ = model.fittedPointSize } onChange: { fired.value = true }
        model.sink.displayChanged(scale: 1, visibleFrame: visible)
        XCTAssertTrue(fired.value, "the window hears that the display changed")
        XCTAssertEqual(model.fittedPointSize, Fit.size(natural: CGSize(width: 3024, height: 1890), limit: CGSize(width: 2960, height: 1880)),
                       "on a 1x display the same pixels take twice the points, fitted to the screen")

        let again = Fired()
        withObservationTracking { _ = model.fittedPointSize } onChange: { again.value = true }
        model.sink.displayChanged(scale: 1, visibleFrame: visible)
        XCTAssertFalse(again.value, "the same display changes nothing")
        await model.stop()
    }
}
