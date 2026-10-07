import XCTest
import AppKit
import CoreVideo
import NitidoCapture
@testable import NitidoUI

/// Stands in for VideoView: records every render, never touches Metal.
@MainActor
private final class FakeDrawing: FrameDrawing {
    var canShowFrames = true
    var drawableCount = 3
    var renderResult: VideoView.Drop?
    private(set) var renders: [(kind: FramePacer.Kind, captureHostTimeNs: UInt64)] = []
    private(set) var presented: [UInt64] = []
    private(set) var drops: [VideoView.Drop] = []

    func render(_ frame: FramePacer.Frame, kind: FramePacer.Kind) -> VideoView.Drop? {
        renders.append((kind, frame.captureHostTimeNs))
        return renderResult
    }
    func framePresented(captureHostTimeNs: UInt64, at presentedAt: Double) { presented.append(captureHostTimeNs) }
    func frameDropped(_ drop: VideoView.Drop) { drops.append(drop) }
    var kinds: [FramePacer.Kind] { renders.map(\.kind) }
}

private func makeBuffer() throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(kCFAllocatorDefault, 8, 6, kCVPixelFormatType_32BGRA, nil, &buffer)
    guard status == kCVReturnSuccess, let buffer else { throw XCTSkip("CVPixelBufferCreate failed: \(status)") }
    return buffer
}

@MainActor
private func frame(_ ns: UInt64) throws -> FramePacer.Frame {
    FramePacer.Frame(pixelBuffer: try makeBuffer(), captureHostTimeNs: ns)
}

final class FramePacerTests: XCTestCase {
    /// The reviewer's case: a still source, then the drawable changes size (the window fitted to the pick, or a
    /// move to a display with another scale). The held frame is drawn once more and is not a new display.
    @MainActor
    func testSizeChangeRedrawsTheHeldFrameOnceWithoutReportingItPresented() throws {
        let host = FakeDrawing()
        let pacer = FramePacer()
        pacer.host = host
        pacer.drawableSize = CGSize(width: 1440, height: 900)
        pacer.present(try frame(100))
        XCTAssertEqual(host.kinds, [.live])
        pacer.drawableReturned(kind: .live, captureHostTimeNs: 100, presentedAt: 1.0)
        XCTAssertEqual(host.presented, [100])

        pacer.drawableSize = CGSize(width: 1440, height: 900)
        XCTAssertEqual(host.kinds, [.live], "the same size is not a change")

        pacer.drawableSize = CGSize(width: 3200, height: 2400)
        XCTAssertEqual(host.kinds, [.live, .redraw])
        XCTAssertEqual(host.renders.last?.captureHostTimeNs, 100, "the redraw draws the held frame")
        pacer.drawableReturned(kind: .redraw, captureHostTimeNs: 100, presentedAt: 1.1)
        XCTAssertEqual(host.presented, [100], "a redraw is not a display or a latency sample")
        XCTAssertTrue(host.drops.isEmpty)
        XCTAssertEqual(pacer.inFlight, 0)
    }

    /// A frame that arrives while the window is minimized, covered or hidden is kept and drawn when it shows.
    @MainActor
    func testFrameSkippedWhileHiddenIsKeptAndDrawnWhenTheWindowShows() throws {
        let host = FakeDrawing()
        let pacer = FramePacer()
        pacer.host = host
        pacer.drawableSize = CGSize(width: 800, height: 600)
        pacer.present(try frame(1))
        pacer.drawableReturned(kind: .live, captureHostTimeNs: 1, presentedAt: 1.0)

        host.canShowFrames = false
        pacer.present(try frame(2))
        XCTAssertEqual(host.drops, [.hidden])
        XCTAssertEqual(host.kinds, [.live])

        host.canShowFrames = true
        pacer.redraw()
        XCTAssertEqual(host.kinds, [.live, .redraw])
        XCTAssertEqual(host.renders.last?.captureHostTimeNs, 2, "the newest frame, not the one on screen")
        pacer.drawableReturned(kind: .redraw, captureHostTimeNs: 2, presentedAt: 2.0)
        XCTAssertEqual(host.presented, [1])
    }

    /// A redraw never exceeds the frames-in-flight cap: it waits for the next drawable, then runs once.
    @MainActor
    func testRedrawAtTheCapWaitsForTheNextDrawable() throws {
        let host = FakeDrawing()
        let pacer = FramePacer()
        pacer.host = host
        pacer.now = { 10 }
        pacer.drawableSize = CGSize(width: 800, height: 600)
        pacer.present(try frame(1))
        pacer.present(try frame(2))
        XCTAssertEqual(pacer.inFlight, 2)

        pacer.drawableSize = CGSize(width: 1600, height: 1200)
        XCTAssertEqual(host.kinds, [.live, .live], "no third drawable while two are in flight")
        XCTAssertTrue(host.drops.isEmpty, "a waiting redraw is not a dropped frame")

        pacer.drawableReturned(kind: .live, captureHostTimeNs: 1, presentedAt: 1.0)
        XCTAssertEqual(host.kinds, [.live, .live, .redraw])
        XCTAssertEqual(host.renders.last?.captureHostTimeNs, 2)
        XCTAssertEqual(pacer.inFlight, 2)

        pacer.drawableReturned(kind: .live, captureHostTimeNs: 2, presentedAt: 1.1)
        pacer.drawableReturned(kind: .redraw, captureHostTimeNs: 2, presentedAt: 1.2)
        XCTAssertEqual(host.kinds.count, 3, "the redraw ran once")
        XCTAssertEqual(host.presented, [1, 2])
    }

    /// A live frame drawn after a redraw was queued already shows the new size: the queued redraw is dropped.
    @MainActor
    func testLiveFrameSupersedesAQueuedRedraw() throws {
        let host = FakeDrawing()
        let pacer = FramePacer()
        pacer.host = host
        pacer.now = { 10 }
        pacer.drawableSize = CGSize(width: 800, height: 600)
        pacer.present(try frame(1))
        pacer.present(try frame(2))
        pacer.drawableSize = CGSize(width: 1600, height: 1200)   // queued: two in flight
        host.drawableCount = 4                                   // room for one more live frame
        pacer.present(try frame(3))
        XCTAssertEqual(host.kinds, [.live, .live, .live])
        pacer.drawableReturned(kind: .live, captureHostTimeNs: 1, presentedAt: 1.0)
        XCTAssertEqual(host.kinds, [.live, .live, .live], "frame 3 already drew at the new size")
    }

    /// Live frames over the cap are still dropped as backlog, and a discarded live drawable is not a display.
    @MainActor
    func testLiveFramesKeepTheirDropAccounting() throws {
        let host = FakeDrawing()
        let pacer = FramePacer()
        pacer.host = host
        pacer.now = { 10 }
        pacer.drawableSize = CGSize(width: 800, height: 600)
        pacer.present(try frame(1))
        pacer.present(try frame(2))
        pacer.present(try frame(3))
        XCTAssertEqual(host.drops, [.backlog])
        pacer.drawableReturned(kind: .live, captureHostTimeNs: 1, presentedAt: 0)
        XCTAssertEqual(host.drops, [.backlog, .notPresented])
        XCTAssertTrue(host.presented.isEmpty)
        pacer.drawableReturned(kind: .redraw, captureHostTimeNs: 3, presentedAt: 0)
        XCTAssertEqual(host.drops, [.backlog, .notPresented], "a discarded redraw is not a dropped frame")
    }

    /// No drawable back for over a second: the count resets and drawing resumes (a lost presented handler).
    @MainActor
    func testStalledBacklogResetsAfterOneSecond() throws {
        let host = FakeDrawing()
        let pacer = FramePacer()
        pacer.host = host
        var clock: CFTimeInterval = 10
        pacer.now = { clock }
        pacer.drawableSize = CGSize(width: 800, height: 600)
        pacer.present(try frame(1))
        pacer.present(try frame(2))
        clock = 11.5
        pacer.present(try frame(3))
        XCTAssertEqual(host.kinds, [.live, .live, .live])
        XCTAssertEqual(pacer.inFlight, 1)
    }

    /// A redraw that fails to render is shown like any render failure; one without a drawable is only logged.
    @MainActor
    func testRedrawFailuresAreReportedOnlyWhenTheyAreRenderFailures() throws {
        let host = FakeDrawing()
        let pacer = FramePacer()
        pacer.host = host
        pacer.drawableSize = CGSize(width: 800, height: 600)
        pacer.present(try frame(1))
        pacer.drawableReturned(kind: .live, captureHostTimeNs: 1, presentedAt: 1.0)

        host.renderResult = .noDrawable
        pacer.redraw()
        XCTAssertTrue(host.drops.isEmpty)
        host.renderResult = .failed("boom")
        pacer.redraw()
        XCTAssertEqual(host.drops, [.failed("boom")])
        XCTAssertEqual(pacer.inFlight, 0, "nothing was committed")
    }

    /// Releasing the held frame (the share stopped) leaves nothing to redraw.
    @MainActor
    func testReleaseLeavesNothingToRedraw() throws {
        let host = FakeDrawing()
        let pacer = FramePacer()
        pacer.host = host
        pacer.drawableSize = CGSize(width: 800, height: 600)
        pacer.present(try frame(1))
        pacer.releaseHeldFrame()
        XCTAssertNil(pacer.held)
        pacer.drawableSize = CGSize(width: 1600, height: 1200)
        pacer.redraw()
        XCTAssertEqual(host.kinds, [.live])
    }
}

final class VideoViewHeldFrameTests: XCTestCase {
    /// A frame pushed while the view has no visible window is kept (and reported hidden); leaving the window
    /// hands it back.
    @MainActor
    func testLeavingTheWindowReleasesTheHeldFrame() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let view = VideoView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = view
        let drops = DropLog()
        view.onDropped = { drops.items.append($0) }

        view.present(try makeBuffer(), captureHostTimeNs: 5)
        XCTAssertEqual(drops.items, [.hidden], "a window never ordered on screen is not visible")
        XCTAssertEqual(view.pacer.held?.captureHostTimeNs, 5)

        window.contentView = nil
        XCTAssertNil(view.pacer.held)
    }

    /// Stop releases the frame the view keeps for redraws.
    @MainActor
    func testShareStopReleasesTheHeldFrame() async throws {
        let model = ShareModel(makeSource: { NeverSource() }, screenRecordingGranted: { true })
        let view = VideoView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        model.sink.view = view
        model.sink.push(try makeBuffer(), captureHostTimeNs: 9)
        XCTAssertEqual(view.pacer.held?.captureHostTimeNs, 9)
        await model.stop()
        XCTAssertNil(view.pacer.held)
    }
}

@MainActor
private final class DropLog {
    var items: [VideoView.Drop] = []
}

/// A capture source that never emits; enough for a model that is only stopped.
@MainActor
private final class NeverSource: CaptureSource {
    let frames = AsyncStream<CapturedFrame> { _ in }
    let events = AsyncStream<CaptureEvent> { _ in }
    func presentPicker(excludingWindowIDs: [CGWindowID]) {}
    func stop() async {}
}
