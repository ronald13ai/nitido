import XCTest
import AppKit
import ScreenCaptureKit
@testable import NitidoCapture

/// Stands in for SCStream: records every configuration it is given.
private final class FakeStream: CaptureStream, @unchecked Sendable {
    private let lock = NSLock()
    private var _sizes: [[Int]] = []
    var sizes: [[Int]] { lock.withLock { _sizes } }
    func updateContentFilter(_ contentFilter: SCContentFilter) async throws {}
    func updateConfiguration(_ streamConfig: SCStreamConfiguration) async throws {
        let size = [streamConfig.width, streamConfig.height]
        lock.withLock { _sizes.append(size) }
    }
    func stopCapture() async throws {}
}

/// Collects the session's events as they come.
@MainActor
private final class EventLog {
    var events: [CaptureEvent] = []
}

private struct TimedOut: Error {}

/// Spec 4 and 12, testing.md item 9: a shared window resized, or a display whose mode changed, restarts the stream at
/// the content's new native size and says so with a new `.started`, once, after the size has settled.
final class CaptureSessionResizeTests: XCTestCase {
    @MainActor
    private func waitUntil(_ what: String, timeout: Double = 5, _ condition: () -> Bool) async throws {
        let deadline = CACurrentMediaTime() + timeout
        while !condition() {
            guard CACurrentMediaTime() < deadline else { XCTFail("timed out waiting until \(what)"); throw TimedOut() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// A session running a fake stream at `width` × `height`, and the log of its events.
    @MainActor
    private func running(width: Int, height: Int, scale: CGFloat = 2, display: CGDirectDisplayID? = nil)
        -> (CaptureSession, FakeStream, EventLog, Task<Void, Never>) {
        let session = CaptureSession()
        session.settle = 0.05
        let stream = FakeStream()
        session.runForTesting(stream, width: width, height: height, scale: scale, display: display)
        let log = EventLog()
        let reader = Task { @MainActor in for await event in session.events { log.events.append(event) } }
        return (session, stream, log, reader)
    }

    /// A 1200 × 800 pt window on a 2x display was configured at 2400 × 1600, then dragged to 1800 × 1100 pt:
    /// ScreenCaptureKit scales it by 2/3 into the old surface. The stream restarts once at 3600 × 2200, and frames at
    /// that size restart nothing more.
    @MainActor
    func testAWindowThatGrewRestartsTheStreamOnceAtItsNativeSize() async throws {
        let (session, stream, log, reader) = running(width: 2400, height: 1600)
        defer { reader.cancel() }
        for _ in 0..<5 {
            session.observeFrameForTesting(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 1100.0 * 2 / 3),
                                           contentScale: 2.0 / 3, scaleFactor: 2)
        }
        try await waitUntil("the stream restarts at the new size") { !log.events.isEmpty }
        XCTAssertEqual(log.events, [.started(pixelWidth: 3600, pixelHeight: 2200, scale: 2)])
        XCTAssertEqual(stream.sizes, [[3600, 2200]])

        for _ in 0..<5 { session.observeFrameForTesting(contentRect: CGRect(x: 0, y: 0, width: 1800, height: 1100), contentScale: 1, scaleFactor: 2) }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(stream.sizes, [[3600, 2200]], "frames at the configured size restart nothing")
        XCTAssertEqual(log.events.count, 1)
    }

    /// A window that shrank sits in a corner of the old surface, unscaled: the stream restarts at its smaller size.
    @MainActor
    func testAWindowThatShrankRestartsTheStreamAtItsSmallerSize() async throws {
        let (session, stream, log, reader) = running(width: 2400, height: 1600)
        defer { reader.cancel() }
        session.observeFrameForTesting(contentRect: CGRect(x: 0, y: 0, width: 500, height: 300), contentScale: 1, scaleFactor: 2)
        try await waitUntil("the stream restarts at the new size") { !log.events.isEmpty }
        XCTAssertEqual(log.events, [.started(pixelWidth: 1000, pixelHeight: 600, scale: 2)])
        XCTAssertEqual(stream.sizes, [[1000, 600]])
    }

    /// A live resize reports a new size every frame: nothing restarts while it goes on, and the stream restarts once,
    /// at the last size, when it stops (the window then goes still and sends no more frames).
    @MainActor
    func testALiveResizeRestartsTheStreamOnceWhenItStops() async throws {
        let (session, stream, log, reader) = running(width: 2400, height: 1600)
        defer { reader.cancel() }
        for step in 1...12 {
            session.observeFrameForTesting(contentRect: CGRect(x: 0, y: 0, width: 1200 + 10 * step, height: 800), contentScale: 1, scaleFactor: 2)
            try await Task.sleep(for: .milliseconds(10))
        }
        try await waitUntil("the stream restarts once the size holds") { !log.events.isEmpty }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(stream.sizes, [[2640, 1600]], "one restart, at the last size")
        XCTAssertEqual(log.events, [.started(pixelWidth: 2640, pixelHeight: 1600, scale: 2)])
    }

    /// Frames whose content matches the configured size restart nothing.
    @MainActor
    func testFramesAtTheConfiguredSizeRestartNothing() async throws {
        let (session, stream, log, reader) = running(width: 2400, height: 1600)
        defer { reader.cancel() }
        for _ in 0..<10 { session.observeFrameForTesting(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800), contentScale: 1, scaleFactor: 2) }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(stream.sizes, [])
        XCTAssertEqual(log.events, [])
    }

    /// A display reconfigured mid-share (`NSApplication.didChangeScreenParametersNotification`): a display share takes
    /// its display's mode as the new size, restarts at it and says the mode's scale.
    @MainActor
    func testADisplayReconfigurationRestartsADisplayShareAtTheModesSize() async throws {
        let display = CGMainDisplayID()
        guard let mode = CGDisplayCopyDisplayMode(display), mode.width > 0, mode.pixelWidth != 64 else { throw XCTSkip("no main display mode") }
        let (_, stream, log, reader) = running(width: 64, height: 64, scale: 1, display: display)
        defer { reader.cancel() }
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        try await waitUntil("the stream restarts at the display's size") { !log.events.isEmpty }
        let scale = CGFloat(mode.pixelWidth) / CGFloat(mode.width)
        XCTAssertEqual(log.events, [.started(pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight, scale: scale)])
        XCTAssertEqual(stream.sizes, [[mode.pixelWidth, mode.pixelHeight]])
    }

    /// A window share ignores display reconfiguration: its next frame says its size.
    @MainActor
    func testADisplayReconfigurationLeavesAWindowShareToItsFrames() async throws {
        let (_, stream, log, reader) = running(width: 64, height: 64, scale: 1)
        defer { reader.cancel() }
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(stream.sizes, [])
        XCTAssertEqual(log.events, [])
    }

    /// Stop drops a restart that was waiting for the size to settle.
    @MainActor
    func testStopDropsAPendingRestart() async throws {
        let (session, stream, log, reader) = running(width: 2400, height: 1600)
        defer { reader.cancel() }
        session.observeFrameForTesting(contentRect: CGRect(x: 0, y: 0, width: 500, height: 300), contentScale: 1, scaleFactor: 2)
        await session.stop()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(stream.sizes, [])
        XCTAssertEqual(log.events, [.stopped])
    }

    /// The content's size at 1:1 undoes ScreenCaptureKit's fit and takes the display's scale; nonsense is ignored.
    func testNativeSize() {
        XCTAssertEqual(SizeWatch.nativeSize(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800), contentScale: 1, scaleFactor: 2),
                       SizeWatch.Size(width: 2400, height: 1600, scale: 2))
        XCTAssertEqual(SizeWatch.nativeSize(contentRect: CGRect(x: 0, y: 0, width: 960, height: 540), contentScale: 0.5, scaleFactor: 1),
                       SizeWatch.Size(width: 1920, height: 1080, scale: 1))
        XCTAssertNil(SizeWatch.nativeSize(contentRect: .zero, contentScale: 1, scaleFactor: 2))
        XCTAssertNil(SizeWatch.nativeSize(contentRect: CGRect(x: 0, y: 0, width: 10, height: 10), contentScale: 0, scaleFactor: 2))
        XCTAssertNil(SizeWatch.nativeSize(contentRect: CGRect(x: 0, y: 0, width: 10, height: 10), contentScale: .nan, scaleFactor: 2))
    }

    /// A display pick is known by its display ID on macOS 15.2 and later, and before that only by its content
    /// rectangle, in a coordinate space no documentation states. Its display is the one with that ID; else the display
    /// whose frame is within a few points of the rectangle in origin and size, the nearest; else, for a pick that names
    /// no display, the only display of that size, wherever the rectangle is; else none, and the pick is shared as picked.
    func testTheDisplayOfAPickIsTheOneWithItsIDOrNearestToItsFrame() {
        let laptop = (id: CGDirectDisplayID(1), frame: CGRect(x: 0, y: 0, width: 1512, height: 982))
        let monitor = (id: CGDirectDisplayID(5), frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440))
        let twins = [(id: CGDirectDisplayID(2), frame: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
                     (id: CGDirectDisplayID(3), frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080))]
        func match(_ rect: CGRect, id: CGDirectDisplayID? = nil,
                   in displays: [(id: CGDirectDisplayID, frame: CGRect)] = [laptop, monitor]) -> Int? {
            CaptureSession.matchingDisplay(displays: displays, pickedID: id, contentRect: rect)?.index
        }
        XCTAssertEqual(match(monitor.frame), 1, "the same frame")
        XCTAssertEqual(match(CGRect(x: 1513.5, y: -1, width: 2559, height: 1440.5)), 1, "a frame a point or two off")
        XCTAssertEqual(match(CGRect(x: 0, y: 0, width: 2560, height: 1440)), 1, "elsewhere, but the only display of that size")
        XCTAssertEqual(match(laptop.frame, id: 5), 1, "the pick's display ID decides over its frame")
        XCTAssertEqual(match(monitor.frame, id: 9), 1, "an ID no display has: the frame decides")
        XCTAssertEqual(match(CGRect(x: 1921, y: 1, width: 1920, height: 1080), in: twins), 1, "two of that size: the near one")
        XCTAssertEqual(match(CGRect(x: 2, y: 0, width: 1920, height: 1080), in: twins), 0)
        XCTAssertNil(match(CGRect(x: 0, y: 500, width: 1920, height: 1080), in: twins), "two of that size, neither near: no guess")
        XCTAssertNil(match(CGRect(x: 0, y: 0, width: 800, height: 600)), "no display of that size")
        XCTAssertNil(match(CGRect(x: 1512, y: 0, width: 2540, height: 1440)), "20 points narrower is another size")

        // A pick that names a display (macOS 15.2 and later) no longer listed: only a display at its frame is it. The
        // only display of that size elsewhere may be its twin, which the user did not pick, so the pick is shared as
        // picked instead.
        XCTAssertNil(match(CGRect(x: 0, y: 0, width: 2560, height: 1440), id: 99), "an unlisted ID: no guess by size")
        let atFrame = CaptureSession.matchingDisplay(displays: [laptop, monitor], pickedID: 99, contentRect: monitor.frame)
        XCTAssertEqual(atFrame?.index, 1)
        XCTAssertEqual(atFrame?.how, "its frame")
        let bySize = CaptureSession.matchingDisplay(displays: [laptop, monitor], pickedID: nil, contentRect: CGRect(x: 0, y: 0, width: 2560, height: 1440))
        XCTAssertEqual(bySize?.index, 1, "a pick without an ID (before macOS 15.2) is still found by its size")
        XCTAssertEqual(bySize?.how, "its size, the only display of it")
    }
}
