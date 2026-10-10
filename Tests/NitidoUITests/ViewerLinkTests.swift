import XCTest
import AppKit
import SwiftUI
import Network
import CoreVideo
import QuartzCore
import dnssd
import OSLog
import NitidoTestSupport
import NitidoCore
@testable import NitidoCodec
@testable import NitidoCapture
@testable import NitidoLink
@testable import NitidoUI

/// Stands in for CaptureSession on the sharing side: emits events and frames on demand.
@MainActor
private final class StillSource: CaptureSource {
    let frames: AsyncStream<CapturedFrame>
    let events: AsyncStream<CaptureEvent>
    private let eventOut: AsyncStream<CaptureEvent>.Continuation
    private let frameOut: AsyncStream<CapturedFrame>.Continuation
    init() {
        (frames, frameOut) = AsyncStream<CapturedFrame>.makeStream()
        (events, eventOut) = AsyncStream<CaptureEvent>.makeStream()
    }
    func presentPicker(excludingWindowIDs: [CGWindowID]) {}
    func stop() async {}
    func emit(_ event: CaptureEvent) { eventOut.yield(event) }
    func emit(frame: CapturedFrame) { frameOut.yield(frame) }
}

/// Makes a fresh source for every session, as the app does: a retired session's streams have ended for good.
@MainActor
private final class SourceFactory {
    private(set) var made: [StillSource] = []
    func make() -> any CaptureSource { let source = StillSource(); made.append(source); return source }
}

/// A captured frame stamped now, in an IOSurface-backed BGRA buffer the hardware encoder takes.
private func stripedFrame(index: Int = 0, width: Int = 320, height: Int = 180) throws -> CapturedFrame {
    var buffer: CVPixelBuffer?
    let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
    let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer)
    guard status == kCVReturnSuccess, let buffer else { throw XCTSkip("CVPixelBufferCreate failed: \(status)") }
    CVPixelBufferLockBaseAddress(buffer, [])
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    for y in 0..<height {
        for x in 0..<width {
            let on = (x + y + index * 7) % 32 < 16
            let p = base + y * stride + x * 4
            p[0] = on ? 0x6a : 0x0c; p[1] = on ? 0xa8 : 0x09; p[2] = on ? 0xc9 : 0x08; p[3] = 0xff
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return CapturedFrame(pixelBuffer: buffer, captureHostTimeNs: UInt64(CACurrentMediaTime() * 1e9),
                         contentRect: CGRect(x: 0, y: 0, width: width / 2, height: height / 2), scale: 2)
}

/// Counts the decoded frames that reach the viewer's sink: with no view on screen each one is reported as hidden, the
/// ones a newer frame replaced on the way included (`FrameSink.dropped`). The viewer's own handler still runs first.
@MainActor
private final class ShownCounter {
    var count = 0
    init(_ sink: FrameSink) {
        let report = sink.onDropped
        sink.onDropped = { [unowned self] drop in
            report?(drop)
            if drop == .hidden { count += 1 }
        }
    }
}

private struct TimedOut: Error {}

/// The sharer's clock for counting wrong codes (`ShareModel.handshakeClock`), moved on by hand.
@MainActor
private final class SharerClock { var now: CFTimeInterval = 1_000 }

/// A real keyframe from the hardware encoder: its parameter sets build a decoder that works.
private func realKeyframe() async throws -> EncodedFrame {
    let encoder = try VideoEncoder(width: 320, height: 180, preferred: .hevc, bitsPerSecond: 2_000_000)
    defer { encoder.invalidate() }
    let (frames, out) = AsyncStream<EncodedFrame>.makeStream()
    encoder.onFrame = { out.yield($0) }
    Task { try? await Task.sleep(for: .seconds(5)); out.finish() }
    XCTAssertTrue(encoder.encode(try stripedFrame().pixelBuffer, captureHostTimeNs: 0))
    for await frame in frames where frame.isKey { return frame }
    throw XCTSkip("the hardware encoder emitted no keyframe within 5 s")
}

/// A real delta frame from the hardware encoder: the frame after a keyframe, with a different picture.
private func realDelta() async throws -> EncodedFrame {
    let encoder = try VideoEncoder(width: 320, height: 180, preferred: .hevc, bitsPerSecond: 2_000_000)
    defer { encoder.invalidate() }
    let (frames, out) = AsyncStream<EncodedFrame>.makeStream()
    encoder.onFrame = { out.yield($0) }
    Task { try? await Task.sleep(for: .seconds(5)); out.finish() }
    var next = frames.makeAsyncIterator()
    XCTAssertTrue(encoder.encode(try stripedFrame(index: 0).pixelBuffer, captureHostTimeNs: 0))
    guard await next.next() != nil else { throw XCTSkip("the hardware encoder emitted no frame within 5 s") }
    XCTAssertTrue(encoder.encode(try stripedFrame(index: 1).pixelBuffer, captureHostTimeNs: 1))
    while let frame = await next.next() { if !frame.isKey { return frame } }
    throw XCTSkip("the hardware encoder emitted no delta frame within 5 s")
}

/// `count` real frames from the hardware encoder, in order: a keyframe, then deltas, each stamped with its index.
private func realFrames(_ count: Int) async throws -> [EncodedFrame] {
    let encoder = try VideoEncoder(width: 320, height: 180, preferred: .hevc, bitsPerSecond: 2_000_000)
    defer { encoder.invalidate() }
    let (frames, out) = AsyncStream<EncodedFrame>.makeStream()
    encoder.onFrame = { out.yield($0) }
    Task { try? await Task.sleep(for: .seconds(10)); out.finish() }
    var next = frames.makeAsyncIterator()
    var encoded: [EncodedFrame] = []
    for index in 0..<count {
        XCTAssertTrue(encoder.encode(try stripedFrame(index: index).pixelBuffer, captureHostTimeNs: UInt64(index)))
        guard let frame = await next.next() else { throw XCTSkip("the hardware encoder emitted no frame within 10 s") }
        encoded.append(frame)
    }
    return encoded
}

/// What `VideoDecoder.submit` answered, from the thread that fed it.
private final class SubmitResults: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [VideoDecoder.SubmitResult] = []
    func append(_ result: VideoDecoder.SubmitResult) { lock.withLock { results.append(result) } }
    var all: [VideoDecoder.SubmitResult] { lock.withLock { results } }
}

/// Feeds `frames` to `decoder` at 58 fps from another thread while the calling thread (the main thread, in a test) is
/// held, as a stall would hold it, and lets it go once every frame has been submitted and decoded. Returns what
/// `submit` answered for each.
func feedAtFiftyEightFpsWhileTheCallingThreadStalls(_ frames: [VideoFrame],
                                                     to decoder: VideoDecoder) -> [VideoDecoder.SubmitResult] {
    let results = SubmitResults()
    let fed = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInteractive).async {
        for frame in frames {
            results.append(decoder.submit(frame))
            usleep(17_000)
        }
        fed.signal()
    }
    fed.wait()
    decoder.drainForTesting()
    return results.all
}

/// The video frames a plain viewer link received, in order, and when each came (`CACurrentMediaTime`).
@MainActor
private final class ReceivedFrames {
    var frames: [VideoFrame] = []
    var times: [CFTimeInterval] = []
    /// When each keyframe came, in order.
    var keyframeTimes: [CFTimeInterval] { zip(frames, times).filter { $0.0.isKey }.map(\.1) }
}

/// Every message a plain viewer link received, in order.
@MainActor
private final class ReceivedMessages { var messages: [Message] = [] }

/// Set by an observation's change handler, which may run on any thread.
private final class Fired: @unchecked Sendable { var value = false }

/// Both ends of a share in one process: a ShareModel fed by a fake capture source and a ViewModel, joined over the
/// real TLS link on the loopback address (the sharer's own listener, so the code and the key are the real ones).
final class ViewerLinkTests: XCTestCase {
    @MainActor
    private func waitUntil(_ what: String, timeout: Double = 10, _ condition: () -> Bool) async throws {
        let deadline = CACurrentMediaTime() + timeout
        while !condition() {
            guard CACurrentMediaTime() < deadline else { XCTFail("timed out waiting until \(what)"); throw TimedOut() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @MainActor
    private func drain() async { for _ in 0..<50 { await Task.yield() } }

    /// A sharer that has started capturing and is listening for viewers.
    @MainActor
    private func listeningShare(width: Int = 320, height: Int = 180) async throws -> (ShareModel, StillSource) {
        let source = StillSource()
        let share = ShareModel(makeSource: { source }, screenRecordingGranted: { true })
        share.start(excludingWindowIDs: [])
        await drain()
        source.emit(.started(pixelWidth: width, pixelHeight: height, scale: 2))
        try await waitUntil("the sharer listens") { share.listeningPort != nil }
        return (share, source)
    }

    @MainActor
    private func peer(for share: ShareModel) -> Peer {
        Peer(id: "loopback", name: share.name, keyName: share.name,
             endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: share.listeningPort!)!))
    }

    /// A plain viewer link paired with `share`, the video frames it receives and the task that reads them, once the
    /// keyframe it paired with has come in. `host` is the loopback address it connects to: the sharer tells viewers
    /// apart by the address they come from.
    @MainActor
    private func rawViewer(of share: ShareModel, host: NWEndpoint.Host = "127.0.0.1")
        async throws -> (link: NitidoLink.Link, received: ReceivedFrames, reader: Task<Void, Never>) {
        let hello = Hello(protocolVersion: protocolVersion, role: .view, name: "Viewer", pixelWidth: 0, pixelHeight: 0, scale: 2)
        let endpoint = NWEndpoint.hostPort(host: host, port: NWEndpoint.Port(rawValue: share.listeningPort!)!)
        let viewer = NitidoLink.Link.connect(to: endpoint, code: share.code, sharerName: share.name, hello: hello)
        let received = ReceivedFrames()
        let reader = Task { @MainActor in
            for await m in viewer.messages {
                if case .videoFrame(let f) = m { received.frames.append(f); received.times.append(CACurrentMediaTime()) }
            }
        }
        do {
            try await waitUntil("the viewer gets the keyframe it paired with") { received.frames.first?.isKey == true }
        } catch {
            reader.cancel(); viewer.close()
            throw error
        }
        return (viewer, received, reader)
    }

    /// The viewer pairs with the code, sees a still window that was captured before it connected (a still source
    /// sends no new frame), and ink, undo and clear go both ways. Stopping the share tells the viewer.
    @MainActor
    func testViewerPairsSeesAStillPictureAndInkGoesBothWays() async throws {
        let (share, source) = try await listeningShare()
        source.emit(frame: try stripedFrame())   // the only frame: the window stays still from here on
        await drain()
        XCTAssertFalse(share.isSending)

        let viewer = ViewModel()
        let shown = ShownCounter(viewer.sink)
        let sharer = peer(for: share)
        viewer.select(sharer)
        XCTAssertEqual(viewer.state, .enteringCode(sharer))
        viewer.code = share.code
        viewer.connect()
        try await waitUntil("the viewer is connected") { viewer.state == .connected }
        try await waitUntil("the sharer sends to the named viewer") { share.isSending && share.viewerName == viewer.name }
        XCTAssertEqual(viewer.sharerName, share.name)

        try await waitUntil("the still picture is decoded and shown on the viewer") { shown.count >= 1 }
        XCTAssertEqual(viewer.pixelSize, CGSize(width: 320, height: 180))
        XCTAssertEqual(viewer.codecLabel, share.codecLabel)
        XCTAssertEqual(viewer.resolutionLabel, "320×180 @2x")
        try await waitUntil("the viewer measures the round trip") { viewer.snapshot.rttMs != nil }
        try await waitUntil("the sharer measures the round trip") { share.snapshot.rttMs != nil }

        // A moving source: every new frame reaches the viewer, with the codec loop off, on, and off again (the loop
        // and the link share one encoder; turning the loop off makes a new one, whose keyframe the viewer takes).
        for loopback in [false, true, false] {
            share.loopback = loopback
            let before = shown.count
            for i in 1...3 {
                source.emit(frame: try stripedFrame(index: i))
                try await Task.sleep(for: .milliseconds(40))
            }
            try await waitUntil("three moving frames reach the viewer, loop \(loopback ? "on" : "off")") { shown.count >= before + 3 }
        }
        XCTAssertEqual(share.state, .capturing)
        XCTAssertEqual(viewer.state, .connected)

        let viewerStroke = viewer.ink.beginLocal(StrokePoint(x: 0.25, y: 0.25, pressure: 1, tMs: 0))
        viewer.ink.endLocal(viewerStroke)
        try await waitUntil("the viewer's stroke reaches the sharer") {
            share.ink.document.strokes.contains { $0.id == viewerStroke && $0.isRemote }
        }
        let sharerStroke = share.ink.beginLocal(StrokePoint(x: 0.75, y: 0.75, pressure: 1, tMs: 0))
        share.ink.endLocal(sharerStroke)
        try await waitUntil("the sharer's stroke reaches the viewer") {
            viewer.ink.document.strokes.contains { $0.id == sharerStroke && $0.isRemote }
        }
        viewer.ink.undoLocal()
        try await waitUntil("the viewer's undo removes its stroke on the sharer") {
            !share.ink.document.strokes.contains { $0.id == viewerStroke }
        }
        XCTAssertTrue(share.ink.document.strokes.contains { $0.id == sharerStroke }, "undo removes only that side's stroke")
        share.ink.clearLocal()
        try await waitUntil("the sharer's clear empties the viewer's ink") { viewer.ink.document.strokes.isEmpty }

        await share.stop()
        try await waitUntil("the viewer hears that the share ended") {
            viewer.state == .failed("The sharer ended the session.", sharer)
        }
        viewer.disconnect()
        XCTAssertEqual(viewer.state, .browsing)
        XCTAssertEqual(viewer.pixelSize, .zero)
    }

    /// Spec 4 and 12: the capture restarts at a new size (a window resized, the display's mode changed, another pick),
    /// and so does the viewer: the encoder is made again for the new size and its keyframe brings the new setup, and the
    /// sharer's hello with the new size and scale reaches the viewer already connected and any viewer that pairs later.
    @MainActor
    func testANewCaptureSizeAndScaleReachTheViewer() async throws {
        let (share, source) = try await listeningShare()
        source.emit(frame: try stripedFrame())
        await drain()
        let sharer = peer(for: share)
        let viewer = ViewModel()
        let shown = ShownCounter(viewer.sink)
        viewer.select(sharer)
        viewer.code = share.code
        viewer.connect()
        try await waitUntil("the picture reaches the viewer") { viewer.state == .connected && shown.count >= 1 }
        XCTAssertEqual(viewer.resolutionLabel, "320×180 @2x")

        source.emit(.started(pixelWidth: 640, pixelHeight: 360, scale: 1))
        source.emit(frame: try stripedFrame(width: 640, height: 360))
        try await waitUntil("the new size and scale reach the viewer") { viewer.pixelSize == CGSize(width: 640, height: 360) && viewer.scale == 1 }
        XCTAssertEqual(viewer.resolutionLabel, "640×360 @1x")
        XCTAssertEqual(share.resolutionLabel.hasPrefix("640×360 @1x"), true, share.resolutionLabel)

        let later = ViewModel()
        later.select(sharer)
        later.code = share.code
        later.connect()
        try await waitUntil("a viewer that pairs later hears the new scale") { later.state == .connected && later.scale == 1 }
        later.disconnect(); viewer.disconnect()
        await share.stop()
    }

    /// The viewer shows the sharer's picture at the same size: 1:1 stays exact, even at a half point. 1001 x 801 px
    /// at 2x is 500.5 x 400.5 pt, which `ViewView` lays out at the top left of a 501 pt wide window, as `ShareView` does.
    /// The display is given to the sink first (a 14-inch MacBook Pro's, at 2x), so the rule does not depend on which
    /// displays this Mac has: with none in a window the viewer would read the main screen, which can be a 1x monitor.
    /// The window then reports its own screen, and the picture keeps the 1:1 size at that screen's scale.
    @MainActor
    func testAOneToOnePictureKeepsItsExactHalfPointSizeOnTheViewer() async throws {
        let (share, source) = try await listeningShare(width: 1001, height: 801)
        source.emit(frame: try stripedFrame(width: 1001, height: 801))
        await drain()
        let viewer = ViewModel()
        let shown = ShownCounter(viewer.sink)
        viewer.select(peer(for: share))
        viewer.code = share.code
        viewer.connect()
        try await waitUntil("the picture reaches the viewer") { shown.count >= 1 }
        XCTAssertEqual(viewer.pixelSize, CGSize(width: 1001, height: 801))
        viewer.sink.displayChanged(scale: 2, visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950))
        XCTAssertEqual(viewer.fittedPointSize, CGSize(width: 500.5, height: 400.5))

        // On screen, as `ShareWindowSizeTests` checks the sharing side: the window takes the content's whole-point
        // size, and the picture sits at its top left with exactly the fitted size: 500.5 x 400.5 pt on a 2x screen,
        // 1001 x 801 on a 1x one.
        _ = NSApplication.shared
        let controller = NSHostingController(rootView: ViewView(model: viewer))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 560, height: 360),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.contentViewController = nil }
        try await waitUntil("the viewer's video view exists") { viewer.sink.view != nil }
        let scale = window.backingScaleFactor
        let natural = CGSize(width: 1001 / scale, height: 801 / scale)
        let visible = try XCTUnwrap(window.screen?.visibleFrame, "the window's screen")
        let room = Fit.limit(visibleFrame: visible)
        guard room.width >= natural.width, room.height >= natural.height else { throw XCTSkip("screen too small for 1:1") }
        try await waitUntil("the sink hears the window's display") { viewer.sink.backingScale == scale }
        XCTAssertEqual(viewer.fittedPointSize, natural, "1:1 at the scale of the window's screen")
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        let fitted = viewer.fittedPointSize
        let fitting = content.fittingSize
        XCTAssertEqual(fitting.width, fitted.width.rounded(.up), accuracy: 0.001, "the window is as wide as the picture")
        window.setContentSize(fitting)
        content.layoutSubtreeIfNeeded()
        let video = try XCTUnwrap(viewer.sink.view)
        let frame = video.convert(video.bounds, to: content)
        let top = content.isFlipped ? frame.minY : content.bounds.height - frame.maxY
        XCTAssertEqual(frame.minX, 0, accuracy: 0.001, "picture x")
        XCTAssertEqual(top, 0, accuracy: 0.001, "picture top")
        XCTAssertEqual(frame.size.width, fitted.width, accuracy: 0.001, "picture width")
        XCTAssertEqual(frame.size.height, fitted.height, accuracy: 0.001, "picture height")

        viewer.disconnect()
        await share.stop()
    }

    /// The viewer's 1:1 size follows the display the picture is on, observably (`FrameSink.displayChanged`), as the
    /// sharer's does: dragged to a display of another scale, the window takes its new size with the strip hidden too.
    @MainActor
    func testTheViewerWindowSizeFollowsTheDisplayThePictureIsOn() async throws {
        let viewer = ViewModel()
        let key = try await realKeyframe()
        viewer.handleIncoming(.hello(Hello(protocolVersion: protocolVersion, role: .share, name: "Mac", pixelWidth: 320, pixelHeight: 180, scale: 2)))
        viewer.handleIncoming(.videoConfig(try XCTUnwrap(key.videoConfig)))
        XCTAssertEqual(viewer.pixelSize, CGSize(width: 320, height: 180))
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
        viewer.sink.displayChanged(scale: 2, visibleFrame: visible)
        XCTAssertEqual(viewer.fittedPointSize, CGSize(width: 160, height: 90), "1:1 on a 2x display")

        let fired = Fired()
        withObservationTracking { _ = viewer.fittedPointSize } onChange: { fired.value = true }
        viewer.sink.displayChanged(scale: 1, visibleFrame: visible)
        XCTAssertTrue(fired.value, "the window hears that the display changed")
        XCTAssertEqual(viewer.fittedPointSize, CGSize(width: 320, height: 180), "1:1 on a 1x display")
        viewer.disconnect()
    }

    /// Spec 17 and docs/testing.md item 3: a picture too large for the viewer's screen is scaled down, and the viewer's
    /// strip says by how much, as the sharer's does; at 1:1 it says nothing more.
    @MainActor
    func testAScaledDownPictureSaysItsScaleOnTheViewer() async throws {
        let viewer = ViewModel()
        let key = try await realKeyframe()
        viewer.handleIncoming(.hello(Hello(protocolVersion: protocolVersion, role: .share, name: "Mac", pixelWidth: 320, pixelHeight: 180, scale: 2)))
        viewer.handleIncoming(.videoConfig(try XCTUnwrap(key.videoConfig)))
        // 160 x 90 pt at 1:1 on a 2x display; a 200 x 200 pt screen leaves 160 x 80 pt for it: 80/90.
        viewer.sink.displayChanged(scale: 2, visibleFrame: CGRect(x: 0, y: 0, width: 200, height: 200))
        XCTAssertEqual(viewer.resolutionLabel, "320×180 @2x · 89%")
        viewer.sink.displayChanged(scale: 2, visibleFrame: CGRect(x: 0, y: 0, width: 2000, height: 1200))
        XCTAssertEqual(viewer.resolutionLabel, "320×180 @2x")
        viewer.disconnect()
    }

    /// Spec 10: the viewer's strip counts the frames the sharer numbered and never sent (skipped for its send backlog,
    /// or failed in its encoder) from the gaps in their sequence numbers.
    @MainActor
    func testSeqGapsCountAsDroppedOnTheViewer() async throws {
        let (share, _) = try await listeningShare()
        let viewer = ViewModel()
        viewer.select(peer(for: share))
        viewer.code = share.code
        viewer.connect()
        try await waitUntil("the viewer is connected") { viewer.state == .connected && share.isSending }
        func delta(_ seq: UInt32) -> VideoFrame { VideoFrame(seq: seq, captureHostTimeNs: 1, isKey: false, data: Data([0, 0, 0, 1, 2])) }
        viewer.handleIncoming(.videoFrame(delta(1)))
        viewer.handleIncoming(.videoFrame(delta(5)))
        try await waitUntil("frames 2, 3 and 4 count as dropped") { viewer.snapshot.droppedLastSecond >= 3 }
        viewer.disconnect()
        await share.stop()
    }

    /// The bitrate in the sharer's strip is what went to the viewer: frames skipped for the send backlog add nothing.
    @MainActor
    func testFramesSkippedForTheBacklogAddNoBitrate() async throws {
        let (share, _) = try await listeningShare()
        let hello = Hello(protocolVersion: protocolVersion, role: .view, name: "Viewer", pixelWidth: 0, pixelHeight: 0, scale: 2)
        let viewer = NitidoLink.Link.connect(to: peer(for: share).endpoint, code: share.code, sharerName: share.name, hello: hello)
        try await waitUntil("the sharer sends to the viewer") { share.isSending }
        let link = try XCTUnwrap(share.link)
        func frame(_ seq: UInt32, isKey: Bool, bytes: Int = 50_000) -> EncodedFrame {
            EncodedFrame(seq: seq, captureHostTimeNs: 1, isKey: isKey, data: Data(count: bytes), parameterSets: [], codec: .hevc, width: 320, height: 180)
        }
        // The viewer's first keyframe goes out (1 kB), so the deltas after it are the backlog rule's to skip. Over a second's
        // worth (sixty frames) waits to be sent, so every one is skipped at once.
        share.handleEncoded(frame(0, isKey: true, bytes: 1_000))
        let congestion = 70 * share.frameBytes
        link.addBacklogForTesting(congestion)
        for seq in 1...5 { share.handleEncoded(frame(UInt32(seq), isKey: false)) }
        try await Task.sleep(for: .milliseconds(400))    // the 250 ms loop publishes the figures
        XCTAssertEqual(share.snapshot.bitrateMbps, 1_000 * 8 / 1e6, accuracy: 1e-9, "the keyframe only: the skipped deltas add nothing")
        XCTAssertGreaterThanOrEqual(share.snapshot.droppedLastSecond, 5)

        link.addBacklogForTesting(-congestion)
        share.handleEncoded(frame(6, isKey: true))
        try await waitUntil("the keyframe that went out counts") { share.snapshot.bitrateMbps >= 50_000 * 8 / 1e6 }
        XCTAssertLessThanOrEqual(share.snapshot.bitrateMbps, 51_000 * 8 / 1e6 + 1e-9, "the two keyframes, and not the skipped deltas")
        viewer.close()
        await share.stop()
    }

    /// The glass-to-glass estimate is shown as it is: one below zero means the clock offset is off, and the strip says
    /// so (the log too) instead of showing 0 ms.
    @MainActor
    func testTheViewerShowsALatencyEstimateBelowZeroAsItIs() async throws {
        let (share, _) = try await listeningShare()
        let viewer = ViewModel()
        viewer.select(peer(for: share))
        viewer.code = share.code
        viewer.connect()
        try await waitUntil("the viewer knows the sharer's clock") { viewer.state == .connected && viewer.snapshot.rttMs != nil }
        // Same Mac, so the offset is about zero: a frame captured 50 ms after it was shown estimates about -50 ms.
        let now = CACurrentMediaTime()
        viewer.sink.onPresented?(UInt64((now + 0.050) * 1e9), now)
        try await waitUntil("the strip shows the estimate") { viewer.snapshot.latencyMs != nil }
        XCTAssertLessThan(try XCTUnwrap(viewer.snapshot.latencyMs), -25, "shown as it is, not as 0")
        viewer.disconnect()
        await share.stop()
    }

    /// A frame the viewer cannot draw is said over the picture and counted as dropped, until a frame reaches the
    /// screen again, as on the sharing side.
    @MainActor
    func testARenderFailureIsShownAndCountedUntilAFrameIsShown() async throws {
        let viewer = ViewModel()
        XCTAssertNil(viewer.renderFailure)
        viewer.sink.onDropped?(.failed("no render pipeline"))
        XCTAssertEqual(viewer.renderFailure, "no render pipeline")
        try await waitUntil("the strip counts the drop") { viewer.snapshot.droppedLastSecond >= 1 }
        viewer.sink.onDropped?(.hidden)
        XCTAssertEqual(viewer.renderFailure, "no render pipeline", "a hidden window is not a failure, nor a recovery")
        viewer.sink.onPresented?(UInt64(CACurrentMediaTime() * 1e9), CACurrentMediaTime())
        XCTAssertNil(viewer.renderFailure)
    }

    /// A connection that has not proved the code leaves the viewer alone: the listener hands it over before its TLS-PSK
    /// handshake, so it may be a port scan or a mistyped code, and neither may end the session of the viewer who
    /// paired. Both are let go once they end, and the picture still reaches the viewer.
    @MainActor
    func testAConnectionThatHasNotProvedTheCodeLeavesTheViewerAlone() async throws {
        let (share, source) = try await listeningShare()
        source.emit(frame: try stripedFrame())
        await drain()
        let viewer = ViewModel()
        let shown = ShownCounter(viewer.sink)
        let sharer = peer(for: share)
        viewer.select(sharer)
        viewer.code = share.code
        viewer.connect()
        try await waitUntil("the sharer sends to the viewer") { share.isSending && share.viewerName == viewer.name }
        try await waitUntil("the viewer shows the picture") { shown.count >= 1 }

        // A port scan: plain TCP that never starts a handshake.
        let probe = NWConnection(to: sharer.endpoint, using: .tcp)
        probe.start(queue: DispatchQueue(label: "probe"))
        try await waitUntil("the sharer holds the probe apart from the viewer") { share.unpairedCount == 1 }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(viewer.state, .connected, "a port scan ended the viewer's session")
        XCTAssertTrue(share.isSending)
        XCTAssertEqual(share.viewerName, viewer.name)
        probe.cancel()
        try await waitUntil("the sharer lets the probe go", timeout: 20) { share.unpairedCount == 0 }
        XCTAssertEqual(share.wrongCodeAttempts, 0, "a port scan says nothing about the code")

        // A mistyped code: the handshake fails.
        let wrong = String(format: "%04d", (Int(share.code)! + 1) % 10_000)
        let hello = Hello(protocolVersion: protocolVersion, role: .view, name: "Guess", pixelWidth: 0, pixelHeight: 0, scale: 2)
        let guess = NitidoLink.Link.connect(to: sharer.endpoint, code: wrong, sharerName: sharer.keyName, hello: hello)
        try await waitUntil("the wrong code fails") { if case .failed = guess.state { return true }; return false }
        try await waitUntil("the sharer lets the guess go") { share.unpairedCount == 0 }
        XCTAssertEqual(share.wrongCodeAttempts, 1, "the mistyped code counts")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(viewer.state, .connected, "a wrong code ended the viewer's session")
        XCTAssertTrue(share.isSending)
        XCTAssertEqual(share.viewerName, viewer.name)

        let before = shown.count
        source.emit(frame: try stripedFrame(index: 1))
        try await waitUntil("a new frame still reaches the viewer") { shown.count > before }
        viewer.disconnect()
        await share.stop()
    }

    /// A share that stops capturing (Stop Sharing in the menu bar ends the stream with an error, or a codec or listener
    /// failure) ends its viewer and its listener: the viewer is told the sharer stopped sharing instead of staying
    /// connected over a frozen picture, and nobody new can pair with a share that sends nothing. Retry listens again.
    @MainActor
    func testAShareThatStopsCapturingEndsTheViewerAndStopsListening() async throws {
        let sources = SourceFactory()
        let share = ShareModel(makeSource: sources.make, screenRecordingGranted: { true })
        share.start(excludingWindowIDs: [])
        try await waitUntil("the session is made") { sources.made.count == 1 }
        sources.made[0].emit(.started(pixelWidth: 320, pixelHeight: 180, scale: 2))
        try await waitUntil("the sharer listens") { share.listeningPort != nil }
        sources.made[0].emit(frame: try stripedFrame())
        let viewer = ViewModel()
        let sharer = peer(for: share)
        viewer.select(sharer)
        viewer.code = share.code
        viewer.connect()
        try await waitUntil("the viewer is connected") { viewer.state == .connected && share.isSending }

        sources.made[0].emit(.failed(CaptureFailure(reason: .stoppedFromMenuBar, detail: "The user stopped the stream")))
        try await waitUntil("the share fails") { share.state == .failed("Sharing was stopped from the menu bar. Press Retry to share again.") }
        try await waitUntil("the viewer hears that the sharer stopped sharing") {
            viewer.state == .failed("\(share.name) stopped sharing.", sharer)
        }
        XCTAssertFalse(share.isSending)
        XCTAssertNil(share.viewerName)
        XCTAssertNil(share.advertiser, "a failed share stops listening")
        XCTAssertNil(share.listeningPort)
        XCTAssertEqual(share.unpairedCount, 0)

        share.retry()
        try await waitUntil("Retry makes a fresh session") { sources.made.count == 2 }
        sources.made[1].emit(.started(pixelWidth: 320, pixelHeight: 180, scale: 2))
        try await waitUntil("Retry listens again") { share.listeningPort != nil }
        viewer.disconnect()
        await share.stop()
    }

    /// A resize the encoder cannot take fails the share, and Retry back at a size it takes works again: a new viewer gets
    /// its keyframe. Before, the failed `makeEncoder` left the encoder it had invalidated in place, Retry reused it at
    /// the old size, and it turned every frame away: the viewer stayed black and the strip counted 60 drops a second.
    /// No hardware encoder takes a picture 100,000 pixels wide, so the encoder cannot start at that size here.
    @MainActor
    func testRetryAfterAnEncoderThatCouldNotStartForANewSizeSendsAgain() async throws {
        let sources = SourceFactory()
        let share = ShareModel(makeSource: sources.make, screenRecordingGranted: { true })
        share.start(excludingWindowIDs: [])
        try await waitUntil("the session is made") { sources.made.count == 1 }
        sources.made[0].emit(.started(pixelWidth: 320, pixelHeight: 180, scale: 2))
        try await waitUntil("the sharer listens") { share.listeningPort != nil }
        sources.made[0].emit(frame: try stripedFrame())
        let (first, _, firstReader) = try await rawViewer(of: share)
        defer { firstReader.cancel() }

        sources.made[0].emit(.started(pixelWidth: 100_000, pixelHeight: 2, scale: 2))
        sources.made[0].emit(frame: try stripedFrame(width: 100_000, height: 2))
        try await waitUntil("the share fails") { share.state != .capturing }
        guard case .failed(let message) = share.state else { return XCTFail("expected a failure, got \(share.state)") }
        XCTAssertTrue(message.hasPrefix("This Mac's hardware video encoder could not start"), message)
        XCTAssertNil(share.encoder, "the encoder that could not start leaves no invalidated one behind")
        XCTAssertEqual(share.codecLabel, "raw")

        share.retry()
        try await waitUntil("Retry makes a fresh session") { sources.made.count == 2 }
        sources.made[1].emit(.started(pixelWidth: 320, pixelHeight: 180, scale: 2))
        try await waitUntil("Retry listens again") { share.listeningPort != nil }
        sources.made[1].emit(frame: try stripedFrame(index: 1))   // the only frame: the source is still from here on
        await drain()
        let (second, received, reader) = try await rawViewer(of: share)
        defer { reader.cancel() }
        XCTAssertEqual(received.frames.first?.isKey, true, "the new viewer gets its keyframe")
        XCTAssertEqual(share.state, .capturing)
        second.close(); first.close()
        await share.stop()
    }

    /// Stop Sharing in the menu bar ends the stream, and the share fails and ends its viewer. The session's system picker
    /// stays up, though: a new pick from it starts a fresh stream (`.started` on the same session), and the share
    /// resumes without Retry, listens again with the same code, and a viewer that pairs sees the new stream's picture.
    @MainActor
    func testANewPickAfterStopSharingResumesTheShareForViewers() async throws {
        let (share, source) = try await listeningShare()
        source.emit(frame: try stripedFrame())
        let first = ViewModel()
        let sharer = peer(for: share)
        first.select(sharer)
        first.code = share.code
        first.connect()
        try await waitUntil("the viewer is connected") { first.state == .connected && share.isSending }

        source.emit(.failed("The user stopped the stream"))
        try await waitUntil("the viewer hears that the sharer stopped sharing") {
            first.state == .failed("\(share.name) stopped sharing.", sharer)
        }
        XCTAssertNil(share.listeningPort)

        let code = share.code
        source.emit(.started(pixelWidth: 320, pixelHeight: 180, scale: 2))
        try await waitUntil("the resumed share listens again") { share.listeningPort != nil }
        XCTAssertEqual(share.state, .capturing)
        XCTAssertEqual(share.code, code, "the same code")
        let viewer = ViewModel()
        let shown = ShownCounter(viewer.sink)
        viewer.select(peer(for: share))
        viewer.code = share.code
        viewer.connect()
        try await waitUntil("a viewer pairs with the resumed share") { viewer.state == .connected && share.isSending }
        source.emit(frame: try stripedFrame(index: 1))
        try await waitUntil("the new stream's picture reaches the viewer") { shown.count >= 1 }
        XCTAssertEqual(share.state, .capturing)
        viewer.disconnect()
        first.disconnect()
        await share.stop()
    }

    /// One viewer at a time: a second viewer that proves the code takes over, the first is told the session ended, and
    /// the sharer hears the new one.
    @MainActor
    func testASecondViewerThatProvesTheCodeTakesOver() async throws {
        let (share, _) = try await listeningShare()
        let sharer = peer(for: share)
        let first = ViewModel()
        first.select(sharer)
        first.code = share.code
        first.connect()
        try await waitUntil("the first viewer is connected") { first.state == .connected && share.isSending }
        XCTAssertEqual(share.connectionCount, 1)

        let second = ViewModel()
        second.select(sharer)
        second.code = share.code
        second.connect()
        try await waitUntil("the second viewer is connected") { second.state == .connected }
        XCTAssertEqual(share.connectionCount, 2, "a viewer taking over is a new connection: the ring draws again")
        try await waitUntil("the first viewer hears that its session ended") {
            first.state == .failed("The sharer ended the session.", sharer)
        }
        XCTAssertTrue(share.isSending)
        XCTAssertEqual(share.unpairedCount, 0)
        let stroke = second.ink.beginLocal(StrokePoint(x: 0.5, y: 0.5, pressure: 1, tMs: 0))
        second.ink.endLocal(stroke)
        try await waitUntil("the second viewer's stroke reaches the sharer") {
            share.ink.document.strokes.contains { $0.id == stroke && $0.isRemote }
        }
        second.disconnect()
        try await waitUntil("the sharer lets the second viewer go") { !share.isSending && share.viewerName == nil }
        first.disconnect()
        await share.stop()
    }

    /// Spec 12: a viewer on another protocol version that types the right code never takes the seat. Its link is ready
    /// only once the hellos match, which they never do, so the paired viewer goes on as it was (before, it was told the
    /// sharer ended its session), and the sharer says over the picture which version the other Mac speaks.
    @MainActor
    func testAViewerOnAnotherProtocolVersionDoesNotTakeOverThePairedOne() async throws {
        let (share, source) = try await listeningShare()
        source.emit(frame: try stripedFrame())
        await drain()
        let (first, _, reader) = try await rawViewer(of: share)
        defer { reader.cancel() }
        XCTAssertEqual(share.connectionCount, 1)

        let newer = Hello(protocolVersion: protocolVersion + 1, role: .view, name: "Newer", pixelWidth: 0, pixelHeight: 0, scale: 2)
        let incompatible = NitidoLink.Link.connect(to: peer(for: share).endpoint, code: share.code, sharerName: share.name, hello: newer)
        var ended: NitidoLink.Link.State?
        for await s in incompatible.states { if case .failed = s { ended = s }; if s == .cancelled { ended = s } }
        XCTAssertNotNil(ended)
        XCTAssertFalse(incompatible.state == .ready)
        try await waitUntil("the sharer says a Mac on another version tried to view") { share.viewerNotice != nil }
        XCTAssertEqual(share.viewerNotice,
                       "Newer runs a different version of Nítido (protocol \(protocolVersion + 1); this Mac speaks \(protocolVersion)). Update both Macs.")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(share.connectionCount, 1, "the paired viewer keeps the seat")
        XCTAssertEqual(first.state, .ready, "the paired viewer is not told the session ended")
        XCTAssertNil(first.byeReason)
        XCTAssertTrue(share.isSending)
        XCTAssertEqual(share.unpairedCount, 0)
        XCTAssertEqual(share.wrongCodeAttempts, 0, "a protocol mismatch is not a wrong code")
        first.close()
        await share.stop()
    }

    /// The viewer's side: a sharer on another protocol version fails the connection on a screen that names both versions,
    /// and never shows Reconnecting.
    @MainActor
    func testASharerOnAnotherProtocolVersionIsNamedOnTheFailureScreen() async throws {
        let newer = Hello(protocolVersion: protocolVersion + 1, role: .share, name: "Sharer", pixelWidth: 0, pixelHeight: 0, scale: 2)
        let advertiser = try Advertiser(name: "Sharer", code: "1234", hello: newer)
        let port = try await advertiser.start()
        defer { advertiser.stop() }
        let sharer = Peer(id: "newer", name: "Sharer", keyName: "Sharer", endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!))
        let viewer = ViewModel()
        viewer.select(sharer)
        viewer.code = "1234"
        viewer.connect()
        var states: [ViewModel.State] = []
        try await waitUntil("the viewer fails") {
            if states.last != viewer.state { states.append(viewer.state) }
            if case .failed = viewer.state { return true }
            return false
        }
        XCTAssertEqual(viewer.state, .failed("Sharer runs a different version of Nítido (protocol \(protocolVersion + 1); this Mac speaks \(protocolVersion)). Update both Macs.", sharer))
        XCTAssertFalse(states.contains { if case .reconnecting = $0 { return true }; return false }, "\(states)")
        XCTAssertFalse(states.contains(.connected), "\(states)")
        viewer.disconnect()
    }

    /// A decoder that keeps throwing is not a silent freeze on the viewer: each throw counts as a dropped frame, every
    /// third lets the decoder go for a fresh one (made from the setup the keyframe it asked for carries), nine in a row
    /// leave the link up, the tenth ends the link and says so. A frame decoded in between starts the count again.
    @MainActor
    func testADecoderThatKeepsThrowingEndsTheLinkAfterTenInARow() async throws {
        let (share, _) = try await listeningShare()
        let viewer = ViewModel()
        let shown = ShownCounter(viewer.sink)
        viewer.select(peer(for: share))
        viewer.code = share.code
        viewer.connect()
        try await waitUntil("the viewer is connected") { viewer.state == .connected && share.isSending }
        let key = try await realKeyframe()
        let config = try XCTUnwrap(key.videoConfig)
        viewer.handleIncoming(.videoConfig(config))
        XCTAssertEqual(viewer.pixelSize, CGSize(width: 320, height: 180))
        // Real parameter sets built a decoder that works; this data is not a picture, so `decode` throws.
        let unreadable = VideoFrame(seq: 1, captureHostTimeNs: 1, isKey: true, data: Data([0, 0, 0, 3, 1, 2, 3]))
        // Decoding runs on the decoder's queue: each failure lands before the next frame goes in. A keyframe that went in
        // while the one before it still waited would supersede it, and that one would never be decoded.
        func failThree() async throws {
            for _ in 0..<3 {
                let before = viewer.decodeFailures
                viewer.handleIncoming(.videoFrame(unreadable))
                try await waitUntil("the frame fails") { viewer.decodeFailures == before + 1 }
            }
        }
        try await failThree()
        // The third throw let the decoder go: until the setup comes again, a keyframe decodes nothing and is no failure.
        viewer.handleIncoming(.videoFrame(key.videoFrame))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(shown.count, 0, "the third throw lets the decoder go")
        XCTAssertEqual(viewer.state, .connected)
        // Stands in for the sharer's answer to each keyframe request: a keyframe carries its setup (`videoConfig`).
        viewer.handleIncoming(.videoConfig(config))
        for _ in 0..<2 {
            try await failThree()
            viewer.handleIncoming(.videoConfig(config))
        }
        XCTAssertEqual(viewer.decodeFailures, 9)
        XCTAssertEqual(viewer.state, .connected, "nine throws in a row leave the link up")
        viewer.handleIncoming(.videoFrame(key.videoFrame))
        try await waitUntil("the fresh decoder shows the keyframe") { shown.count >= 1 }
        XCTAssertEqual(viewer.decodeFailures, 0)
        for _ in 0..<3 {
            try await failThree()
            viewer.handleIncoming(.videoConfig(config))
        }
        XCTAssertEqual(viewer.state, .connected, "a frame decoded in between starts the count again")
        viewer.handleIncoming(.videoFrame(unreadable))
        try await waitUntil("the tenth failure lands") { viewer.state != .connected }
        // Spec 12: "after ten, show an error with Reconnect", to the same Mac with the same code.
        XCTAssertEqual(viewer.state, .failed("Video decoding keeps failing.", peer(for: share)))
        XCTAssertTrue(viewer.failureOffersReconnect)
        XCTAssertEqual(viewer.pixelSize, .zero)
        try await waitUntil("the strip counts every throw as dropped") { viewer.snapshot.droppedLastSecond >= 19 }
        try await waitUntil("the sharer lets the viewer go") { !share.isSending && share.viewerName == nil }
        viewer.reconnect()
        try await waitUntil("Reconnect pairs again with the code typed") { viewer.state == .connected && share.isSending }
        XCTAssertFalse(viewer.failureOffersReconnect)
        viewer.disconnect()
        await share.stop()
    }

    /// A sharer that drops without saying bye (a cable pull, a process that died) puts the viewer in Reconnecting, and
    /// the viewer pairs again by itself as soon as the sharer answers, asking for a keyframe.
    @MainActor
    func testTheViewerReconnectsWhenTheSharerDropsWithoutBye() async throws {
        let advertiser = try Advertiser(name: "Sharer", code: "1234",
                                        hello: Hello(protocolVersion: protocolVersion, role: .share, name: "Sharer", pixelWidth: 320, pixelHeight: 180, scale: 2))
        let port = try await advertiser.start()
        defer { advertiser.stop() }
        let sharer = Peer(id: "loopback", name: "Sharer", keyName: "Sharer", endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!))
        let viewer = ViewModel()
        viewer.select(sharer)
        viewer.code = "1234"
        viewer.connect()
        var incoming = advertiser.incoming.makeAsyncIterator()
        guard let first = await incoming.next() else { return XCTFail("no connection") }
        try await waitUntil("the viewer is connected") { viewer.state == .connected }
        XCTAssertEqual(viewer.connectionCount, 1)
        first.abort()
        try await waitUntil("the viewer says it is reconnecting") { viewer.state == .reconnecting(sharer, attempt: 1) }
        XCTAssertEqual(viewer.connectionCount, 1, "losing the link is not a connection")
        guard let second = await incoming.next() else { return XCTFail("no reconnect") }
        try await waitUntil("the viewer is connected again") { viewer.state == .connected }
        XCTAssertEqual(viewer.connectionCount, 2, "pairing again is a new connection: the ring draws again")
        // Bounded, so a missing request fails the test instead of hanging it: cancelling the task ends the iteration.
        let asked = Task { () -> Bool in
            for await m in second.messages where m == .keyframeRequest { return true }
            return false
        }
        let deadline = Task { try await Task.sleep(for: .seconds(5)); asked.cancel() }
        let askedForKeyframe = await asked.value
        deadline.cancel()
        XCTAssertTrue(askedForKeyframe, "a viewer that pairs again asks for a keyframe")
        viewer.disconnect()
    }

    /// With no decoder (a decode error let it go, and the setup that makes the next one has not come yet), every frame
    /// that arrives used to ask the sharer for a keyframe, 60 requests a second, and a sharer that gets several in a row
    /// can send a keyframe for each. The viewer asks at most once a second, as its other keyframe requests do.
    @MainActor
    func testAViewerWithNoDecoderAsksForAKeyframeAtMostOnceASecond() async throws {
        let advertiser = try Advertiser(name: "Sharer", code: "1234",
                                        hello: Hello(protocolVersion: protocolVersion, role: .share, name: "Sharer", pixelWidth: 320, pixelHeight: 180, scale: 2))
        let port = try await advertiser.start()
        defer { advertiser.stop() }
        let sharer = Peer(id: "loopback", name: "Sharer", keyName: "Sharer", endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!))
        let viewer = ViewModel()
        viewer.select(sharer)
        viewer.code = "1234"
        viewer.connect()
        var incoming = advertiser.incoming.makeAsyncIterator()
        guard let link = await incoming.next() else { return XCTFail("no connection") }
        let received = ReceivedMessages()
        let reader = Task { @MainActor in for await m in link.messages { received.messages.append(m) } }
        defer { reader.cancel() }
        func requests() -> Int { received.messages.filter { $0 == .keyframeRequest }.count }
        try await waitUntil("the viewer is connected and asks for its first keyframe") { viewer.state == .connected && requests() == 1 }
        func frame(_ seq: UInt32) -> Message {
            .videoFrame(VideoFrame(seq: seq, captureHostTimeNs: 1, isKey: seq == 0, data: Data([0, 0, 0, 1, 2])))
        }
        // The keyframe ends the wait for one; no setup came, so there is no decoder, and the frames keep coming.
        for seq in 0..<30 { viewer.handleIncoming(frame(UInt32(seq))) }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(requests(), 1, "the request from .ready is under a second old")
        try await Task.sleep(for: .seconds(1))
        for seq in 30..<40 { viewer.handleIncoming(frame(UInt32(seq))) }
        try await waitUntil("a second later the viewer asks again") { requests() == 2 }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(requests(), 2, "once for those ten frames")
        viewer.disconnect()
    }

    /// A sharer that died and came back with a new code (every launch makes one) on another port, which discovery
    /// reports, turns the viewer's reconnect away in the handshake: the viewer dials what discovery says now and asks for
    /// the new code instead of saying Reconnecting forever, which would also cost the sharer a failed handshake every few
    /// seconds and rotate its code under whoever is typing it.
    @MainActor
    func testAViewerWhoseSharerCameBackWithANewCodeAsksForIt() async throws {
        let sharerHello = Hello(protocolVersion: protocolVersion, role: .share, name: "Sharer", pixelWidth: 320, pixelHeight: 180, scale: 2)
        let first = try Advertiser(name: "Sharer", code: "1234", hello: sharerHello)
        let firstPort = try await first.start()
        // As discovery lists it: a Bonjour service that never resolves, and the loopback address on the listener's port.
        let service = NWEndpoint.service(name: "Absent \(UInt32.random(in: 0..<1_000_000))", type: "_nitido._tcp", domain: "local.", interface: nil)
        func listed(on port: UInt16) -> Peer {
            Peer(id: "sharer", name: "Sharer", keyName: "Sharer", endpoint: service, addresses: [IPv4Address("127.0.0.1")!], port: port)
        }
        let sharer = listed(on: firstPort)
        let viewer = ViewModel(startingDiscovery: false)
        viewer.peers = [sharer]
        viewer.select(sharer)
        viewer.code = "1234"
        viewer.connect()
        var incoming = first.incoming.makeAsyncIterator()
        guard let dropped = await incoming.next() else { return XCTFail("no connection") }
        try await waitUntil("the viewer is connected") { viewer.state == .connected }
        // The sharer dies without bye and comes back with a new code on another port (a new one every launch), which
        // discovery reports under the same service.
        let relaunched = try Advertiser(name: "Sharer", code: "5678", hello: sharerHello)
        let newPort = try await relaunched.start()
        let attempts = Task { () -> Int in var held: [NitidoLink.Link] = []; for await l in relaunched.incoming { held.append(l) }; return held.count }
        viewer.peers = [listed(on: newPort)]
        dropped.abort(); first.stop()
        try await waitUntil("the viewer asks for the new code", timeout: 15) {
            viewer.state == .failed("The code on Sharer has changed. Enter the new code to connect again.", sharer)
        }
        try await Task.sleep(for: .seconds(2))           // longer than the next backoff: nothing tries again
        relaunched.stop()
        let tried = await attempts.value
        XCTAssertEqual(tried, 1, "one failed handshake on the sharer, not one every few seconds")
        viewer.retry()
        XCTAssertEqual(viewer.state, .enteringCode(sharer))
    }

    /// A skip outlives the encoder when the codec loop is turned off during it (the encoder goes with the loop): the
    /// keyframe that ends the skip is still asked for once the backlog drains, and a fresh encoder makes it from the
    /// newest frame, so the viewer of a still source does not keep the picture from before the skip.
    @MainActor
    func testTheDrainSendsAKeyframeAfterTheLoopTurnedOffDuringASkip() async throws {
        let (share, source) = try await listeningShare()
        source.emit(frame: try stripedFrame())           // the only frame: the source is still from here on
        await drain()
        let (viewer, received, reader) = try await rawViewer(of: share)
        defer { reader.cancel() }
        share.loopback = true
        try await waitUntil("the loop's encoder sends its keyframe") { received.keyframeTimes.count == 2 }
        let link = try XCTUnwrap(share.link)
        let delta = try await realDelta()

        let congestion = 70 * share.frameBytes
        link.addBacklogForTesting(congestion)
        for _ in 0..<3 { share.handleEncoded(delta) }   // over a second's worth: skipped from the first
        let sent = received.frames.count
        share.loopback = false
        XCTAssertNil(share.encoder, "the encoder goes with the loop")
        link.addBacklogForTesting(-congestion)
        try await waitUntil("a keyframe follows the drain", timeout: 3) { received.frames.count > sent }
        XCTAssertTrue(received.frames[sent].isKey, "the first frame after the skip is a keyframe")
        viewer.close()
        await share.stop()
    }

    /// Spec section 8: once frames are dropped for the send backlog, no delta goes out (it would refer to frames the
    /// viewer never got) until a keyframe has, and that keyframe follows as soon as the backlog drains under one frame,
    /// even from a source that went still and sends no frame that could check the drain. A backlog over a second's
    /// worth starts the skip at its first reading
    /// (`testABacklogThatLastsAHundredMillisecondsSkipsDeltasUntilOneKeyframeAndCutsTheRateAtOnce` has the rule for one
    /// under that).
    @MainActor
    func testAfterABacklogDropOnlyAKeyframeGoesOutEvenFromAStillSource() async throws {
        let (share, source) = try await listeningShare()
        source.emit(frame: try stripedFrame())           // the only frame: the source is still from here on
        await drain()
        let hello = Hello(protocolVersion: protocolVersion, role: .view, name: "Viewer", pixelWidth: 0, pixelHeight: 0, scale: 2)
        let viewer = NitidoLink.Link.connect(to: peer(for: share).endpoint, code: share.code, sharerName: share.name, hello: hello)
        let received = ReceivedFrames()
        let reader = Task { @MainActor in
            for await m in viewer.messages { if case .videoFrame(let f) = m { received.frames.append(f) } }
        }
        defer { reader.cancel() }
        try await waitUntil("the viewer gets the keyframe it paired with") { received.frames.first?.isKey == true }
        let link = try XCTUnwrap(share.link)
        let delta = try await realDelta()
        let sent = received.frames.count

        // Congested: over a second's worth (sixty frames) waits to be sent, so deltas are skipped from the first.
        let congestion = 70 * share.frameBytes
        link.addBacklogForTesting(congestion)
        for _ in 0..<3 { share.handleEncoded(delta) }
        try await Task.sleep(for: .milliseconds(400))    // the 250 ms loop runs, and sends no keyframe yet
        XCTAssertEqual(received.frames.count, sent, "nothing goes out while the backlog is over a second's worth")

        // Draining, but still over one frame: a delta now would refer to the frames just skipped.
        let draining = 5 * share.frameBytes / 2
        link.addBacklogForTesting(draining - congestion)
        for _ in 0..<3 { share.handleEncoded(delta) }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(received.frames.count, sent, "no delta after a drop, and no keyframe before the drain")

        // Drained, and the source is still: no frame comes to check the drain, the 250 ms loop sends the keyframe.
        link.addBacklogForTesting(-draining)
        try await waitUntil("a keyframe follows the drain") { received.frames.count > sent }
        XCTAssertTrue(received.frames[sent].isKey, "the first frame after the drop is a keyframe")

        // With the keyframe there, deltas go out again.
        let keyed = received.frames.count
        share.handleEncoded(delta)
        try await waitUntil("deltas go out again") { received.frames.count > keyed }
        XCTAssertFalse(received.frames[keyed].isKey)
        viewer.close()
        await share.stop()
    }

    /// Spec section 8 and the two-Mac test of 2026-10-09: a keyframe still being sent is not congestion, and neither is
    /// a burst that drains within 100 ms. At 2 Mbps (a 320×180 picture) 150 kB is 600 ms worth, four times the
    /// threshold and under the second's worth that skips at once. A 150 kB keyframe that takes 50 ms to go out, a burst
    /// of other bytes as large that drains as fast, then a keyframe as large that takes 200 ms (only its own bytes
    /// held, so only leaving it out of the backlog keeps that one from counting): every delta goes out, none counts as
    /// dropped, no keyframe is asked for after them and the log says nothing of a skip. The rule before skipped the
    /// deltas after each and sent a keyframe once each drained: the slideshow of keyframes the Pro's log showed while
    /// text scrolled.
    @MainActor
    func testAKeyframeOrABurstThatDrainsWithinFiftyMillisecondsSkipsNothing() async throws {
        let (share, source) = try await listeningShare()
        source.emit(frame: try stripedFrame())           // the only frame: the source is still from here on
        await drain()
        let clock = SharerClock()
        share.backlogClock = { clock.now }
        let (viewer, received, reader) = try await rawViewer(of: share)
        defer { reader.cancel() }
        let link = try XCTUnwrap(share.link)
        let delta = try await realDelta()
        let mark = LogMark()
        let sent = received.frames.count

        // A 150 kB keyframe goes out and takes 50 ms to (the loopback sends it at once: once it has, the test holds its
        // bytes, as the keyframe on its way).
        share.handleEncoded(EncodedFrame(seq: 100, captureHostTimeNs: 1, isKey: true, data: Data(count: 150_000), parameterSets: [],
                                         codec: .hevc, width: 320, height: 180))
        try await waitUntil("the loopback has taken the first keyframe") { link.backlogBytes == 0 }
        link.addBacklogForTesting(150_000, keyframe: true)
        for _ in 0..<3 { share.handleEncoded(delta); clock.now += 1.0 / 60 }
        link.addBacklogForTesting(-150_000, keyframe: true)
        share.handleEncoded(delta); clock.now += 1.0 / 60

        // A burst of other bytes as large, gone within 50 ms too.
        link.addBacklogForTesting(150_000)
        for _ in 0..<3 { share.handleEncoded(delta); clock.now += 1.0 / 60 }
        link.addBacklogForTesting(-150_000)
        share.handleEncoded(delta); clock.now += 1.0 / 60

        // A keyframe as large that takes 200 ms to go out.
        share.handleEncoded(EncodedFrame(seq: 200, captureHostTimeNs: 1, isKey: true, data: Data(count: 150_000), parameterSets: [],
                                         codec: .hevc, width: 320, height: 180))
        try await waitUntil("the loopback has taken the second keyframe") { link.backlogBytes == 0 }
        link.addBacklogForTesting(150_000, keyframe: true)
        for _ in 0..<12 { share.handleEncoded(delta); clock.now += 1.0 / 60 }
        link.addBacklogForTesting(-150_000, keyframe: true)

        try await waitUntil("the two keyframes and the twenty deltas reach the viewer") { received.frames.count >= sent + 22 }
        try await Task.sleep(for: .milliseconds(600))    // the 250 ms loop runs twice: a keyframe after a drain would be out
        let after = Array(received.frames[sent...])
        XCTAssertEqual(after.count, 22, "the two keyframes and twenty deltas, nothing more")
        XCTAssertEqual(after.filter(\.isKey).count, 2, "no keyframe after a drain")
        XCTAssertEqual(share.snapshot.droppedLastSecond, 0)
        let lines = try mark.entries("share").map(\.composedMessage)
        XCTAssertEqual(lines.filter { $0.contains("skipping frames") || $0.contains("the send backlog drained") }, [])
        viewer.close()
        await share.stop()
    }

    /// Spec section 8: a backlog over 150 ms worth that lasts 100 ms skips the deltas from then on, until the one
    /// keyframe asked for once it drains, every skipped delta counts as dropped, and the bitrate controller cuts for
    /// the skip at its next update although it cut less than 2 s before. At 20 Mbps (a 1920×1080 picture) a megabyte is
    /// 400 ms worth: over the threshold, under a second's worth, and still so after both cuts.
    @MainActor
    func testABacklogThatLastsAHundredMillisecondsSkipsDeltasUntilOneKeyframeAndCutsTheRateAtOnce() async throws {
        let (share, source) = try await listeningShare(width: 1920, height: 1080)
        source.emit(frame: try stripedFrame(width: 1920, height: 1080))
        await drain()
        let clock = SharerClock()
        share.backlogClock = { clock.now }
        let (viewer, received, reader) = try await rawViewer(of: share)
        defer { reader.cancel() }
        let link = try XCTUnwrap(share.link)
        let delta = try await realDelta()
        let mark = LogMark()
        let sent = received.frames.count
        let droppedBefore = share.droppedFramesTotal
        let congestion = 1_000_000

        // Over the threshold from here on. The first delta goes out, and the next update cuts the rate for the backlog.
        let rateBefore = share.frameBytes
        link.addBacklogForTesting(congestion)
        share.handleEncoded(delta)
        try await waitUntil("the controller cuts the rate for the backlog") { share.frameBytes < rateBefore }
        let firstCut = share.frameBytes
        clock.now += 0.05
        share.handleEncoded(delta)                        // over for 50 ms: goes out
        clock.now += 0.05
        share.handleEncoded(delta)                        // over for 100 ms: skipped, and the skip starts
        clock.now += 0.05
        share.handleEncoded(delta)                        // skipped
        try await waitUntil("the two deltas from before the 100 ms reach the viewer") { received.frames.count >= sent + 2 }
        try await waitUntil("the skip cuts the rate at the next update, within the first cut's hold", timeout: 1) {
            share.frameBytes < firstCut
        }
        XCTAssertEqual(received.frames.count, sent + 2, "nothing goes out from the 100 ms on")

        // Drained: still no delta, and the keyframe is asked for, once.
        link.addBacklogForTesting(-congestion)
        clock.now += 0.05
        share.handleEncoded(delta)
        try await waitUntil("a keyframe follows the drain") { received.frames.count > sent + 2 }
        XCTAssertTrue(received.frames[sent + 2].isKey, "the first frame after the skip is a keyframe")
        // Counted over the whole share, not the strip's last second, which a slow run can slide past the first skips.
        XCTAssertEqual(share.droppedFramesTotal - droppedBefore, 3, "the strip counts the three skipped deltas")
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(received.frames[(sent + 2)...].filter(\.isKey).count, 1, "one keyframe after the drain")

        // With the keyframe there, deltas go out again.
        let keyed = received.frames.count
        clock.now += 0.05
        share.handleEncoded(delta)
        try await waitUntil("deltas go out again") { received.frames.count > keyed }
        XCTAssertFalse(received.frames[keyed].isKey)
        let lines = try mark.entries("share").map(\.composedMessage)
        XCTAssertEqual(lines.filter { $0.contains("skipping frames until a keyframe") }.count, 1, lines.joined(separator: "\n"))
        XCTAssertEqual(lines.filter { $0.contains("the send backlog drained") }.count, 1, lines.joined(separator: "\n"))
        viewer.close()
        await share.stop()
    }

    /// The re-review of 2026-10-09: the controller's ordinary cut shrinks the dropping rule's threshold by a quarter,
    /// and an unchanged backlog of 120 ms worth at the rate before the cut is 160 ms worth after it. For half a second
    /// after the cut the rule judges it at the rate before, so the cut does not trip a skip, and a second cut, by
    /// itself: 300 ms of deltas over it all go out.
    @MainActor
    func testAnOrdinaryCutDoesNotTripTheDroppingRuleByItself() async throws {
        let (share, source) = try await listeningShare(width: 1920, height: 1080)
        source.emit(frame: try stripedFrame(width: 1920, height: 1080))
        await drain()
        let clock = SharerClock()
        share.backlogClock = { clock.now }
        let (viewer, received, reader) = try await rawViewer(of: share)
        defer { reader.cancel() }
        let link = try XCTUnwrap(share.link)
        let delta = try await realDelta()
        let mark = LogMark()

        // 7.2 frames are 120 ms worth: under the threshold of 150 ms (nine frames), over the controller's two frames.
        let before = share.frameBytes
        let backlog = before * 72 / 10
        link.addBacklogForTesting(backlog)
        try await waitUntil("the controller cuts the rate for the backlog") { share.frameBytes < before }
        XCTAssertGreaterThan(backlog, 9 * share.frameBytes, "over 150 ms worth at the rate after the cut")
        let sent = received.frames.count
        for _ in 0..<18 { clock.now += 1.0 / 60; share.handleEncoded(delta) }
        try await waitUntil("the 300 ms of deltas reach the viewer") { received.frames.count >= sent + 18 }
        let skips = try mark.entries("share").map(\.composedMessage).filter { $0.contains("skipping frames") }
        XCTAssertEqual(skips, [], "the cut tripped no skip by itself")
        link.addBacklogForTesting(-backlog)
        viewer.close()
        await share.stop()
    }

    /// Spec section 8: a backlog over a second's worth skips at its first reading, and for 500 ms after the keyframe
    /// that ends a skip only that does: a backlog over 150 ms worth that lasts longer than 100 ms in that time skips
    /// nothing, so the keyframe and the link get their time. At 2 Mbps a second's worth is 250 kB.
    @MainActor
    func testOnlyABacklogOverASecondsWorthSkipsAtOnceOrJustAfterAKeyframe() async throws {
        let (share, source) = try await listeningShare()
        source.emit(frame: try stripedFrame())           // the only frame: the source is still from here on
        await drain()
        let clock = SharerClock()
        share.backlogClock = { clock.now }
        let (viewer, received, reader) = try await rawViewer(of: share)
        defer { reader.cancel() }
        let link = try XCTUnwrap(share.link)
        let delta = try await realDelta()
        let mark = LogMark()
        let sent = received.frames.count

        // Over a second's worth: the first delta is skipped. Drained: the keyframe goes out, and the hold-off starts.
        link.addBacklogForTesting(400_000)
        share.handleEncoded(delta)
        link.addBacklogForTesting(-400_000)
        clock.now += 0.02
        share.handleEncoded(delta)
        try await waitUntil("the keyframe follows the drain") { received.frames.count > sent }
        XCTAssertEqual(received.frames[sent...].map(\.isKey), [true], "no delta before the keyframe")

        // In the hold-off: over 150 ms worth for 360 ms, and every delta goes out.
        let keyed = received.frames.count
        link.addBacklogForTesting(100_000)
        for _ in 0..<5 { clock.now += 0.09; share.handleEncoded(delta) }
        try await waitUntil("the deltas in the hold-off go out") { received.frames.count >= keyed + 5 }

        // Still in it: over a second's worth skips at once; once that drains, the keyframe goes out.
        link.addBacklogForTesting(300_000)
        clock.now += 0.01
        share.handleEncoded(delta)
        link.addBacklogForTesting(-400_000)
        try await waitUntil("a keyframe follows that drain too") { received.frames.count > keyed + 5 }
        XCTAssertEqual(received.frames[keyed...].map(\.isKey), [false, false, false, false, false, true])
        let skips = try mark.entries("share").map(\.composedMessage)
            .filter { $0.contains("skipping frames until a keyframe") }
        XCTAssertEqual(skips.count, 2, skips.joined(separator: "\n"))
        XCTAssertTrue(skips.allSatisfy { $0.contains("over a second's worth") }, skips.joined(separator: "\n"))
        viewer.close()
        await share.stop()
    }

    /// Spec section 8 and the re-review of 2026-10-09: only the keyframe on its way is left out of the backlog.
    /// Keyframes stacked behind it (a viewer that keeps asking for one) count for the threshold, the ceiling and the
    /// bitrate controller, so a stream made of keyframes is caught like any other backlog. At 1920×1080 (20 Mbps) a
    /// second's worth is 2.5 MB: three 2 MB keyframes held leave 4 MB that count, so the next delta trips with "over a
    /// second's worth", and the next update cuts the rate.
    @MainActor
    func testKeyframesStackedBehindTheOneOnItsWayCountForTheCeilingAndTheController() async throws {
        let (share, source) = try await listeningShare(width: 1920, height: 1080)
        source.emit(frame: try stripedFrame(width: 1920, height: 1080))
        await drain()
        let (viewer, received, reader) = try await rawViewer(of: share)
        defer { reader.cancel() }
        let link = try XCTUnwrap(share.link)
        let delta = try await realDelta()
        let mark = LogMark()
        let sent = received.frames.count
        let rateBefore = share.frameBytes

        for _ in 0..<3 { link.addBacklogForTesting(2_000_000, keyframe: true) }
        share.handleEncoded(delta)
        try await waitUntil("the next update cuts the rate") { share.frameBytes < rateBefore }
        XCTAssertEqual(received.frames.count, sent, "the delta was skipped")
        let skips = try mark.entries("share").map(\.composedMessage)
            .filter { $0.contains("skipping frames until a keyframe") }
        XCTAssertEqual(skips.count, 1, skips.joined(separator: "\n"))
        XCTAssertTrue(skips.allSatisfy { $0.contains("over a second's worth") }, skips.joined(separator: "\n"))
        for _ in 0..<3 { link.addBacklogForTesting(-2_000_000, keyframe: true) }
        viewer.close()
        await share.stop()
    }

    /// The keyframe on its way is not congestion for the bitrate controller either: at 1920×1080 a megabyte is 400 ms
    /// worth, far over the controller's two frames, but one keyframe held across two 250 ms updates cuts nothing. Fed
    /// the whole backlog, the controller cut 25% at the first update; the 45.6 Mbps the two-Mac test starts at rests on
    /// this.
    @MainActor
    func testOneKeyframeOnItsWayCutsNothing() async throws {
        let (share, source) = try await listeningShare(width: 1920, height: 1080)
        source.emit(frame: try stripedFrame(width: 1920, height: 1080))
        await drain()
        let (viewer, _, reader) = try await rawViewer(of: share)
        defer { reader.cancel() }
        let link = try XCTUnwrap(share.link)
        let rateBefore = share.frameBytes

        link.addBacklogForTesting(1_000_000, keyframe: true)
        try await Task.sleep(for: .milliseconds(600))    // the 250 ms loop updates the controller twice
        XCTAssertGreaterThanOrEqual(share.frameBytes, rateBefore, "the rate is not cut for the keyframe on its way")
        link.addBacklogForTesting(-1_000_000, keyframe: true)
        viewer.close()
        await share.stop()
    }

    /// Spec section 8 and the evening two-Mac test of 2026-10-09: a viewer that asks for a keyframe again and again
    /// (its decoder falling behind under a storm of them) gets at most one forced keyframe per half second, and its
    /// last ask is still answered. Asks every 100 ms for 1.2 s over a still source, where each forced keyframe is a frame
    /// encoded again: before, every ask sent one.
    @MainActor
    func testAViewerThatKeepsAskingGetsAtMostOneKeyframePerHalfSecond() async throws {
        let (share, source) = try await listeningShare()
        source.emit(frame: try stripedFrame())           // the only frame: the source is still from here on
        await drain()
        let (viewer, received, reader) = try await rawViewer(of: share)
        defer { reader.cancel() }
        let paired = received.keyframeTimes.count

        let started = CACurrentMediaTime()
        var lastAsk = started
        for _ in 0..<12 {
            viewer.send(.keyframeRequest)
            lastAsk = CACurrentMediaTime()
            try await Task.sleep(for: .milliseconds(100))
        }
        try await waitUntil("a keyframe answers the last ask") { (received.keyframeTimes.last ?? 0) > lastAsk }
        try await Task.sleep(for: .milliseconds(700))    // anything more the asks set off is out by now
        let times = received.keyframeTimes
        let answered = times.count - paired
        let seen = "\(times.map { $0 - started })"
        XCTAssertGreaterThanOrEqual(answered, 2, "the asks are answered: \(seen)")
        XCTAssertLessThanOrEqual(answered, 4, "at most one per half second over 1.2 s and the wait after: \(seen)")
        for (a, b) in zip(times, times.dropFirst()) { XCTAssertGreaterThan(b - a, 0.4, "half a second apart: \(seen)") }
        viewer.close()
        await share.stop()
    }

    /// The sharer's own forced keyframes share the viewer's limit: the keyframe after a drain, asked for just after the
    /// one the viewer paired with, goes out half a second after that one, not at once.
    @MainActor
    func testTheKeyframeAfterADrainWaitsHalfASecondAfterTheLastForcedOne() async throws {
        let (share, source) = try await listeningShare()
        source.emit(frame: try stripedFrame())           // the only frame: the source is still from here on
        await drain()
        let (viewer, received, reader) = try await rawViewer(of: share)
        defer { reader.cancel() }
        let link = try XCTUnwrap(share.link)
        let paired = try XCTUnwrap(received.keyframeTimes.first)
        let delta = EncodedFrame(seq: 50, captureHostTimeNs: 1, isKey: false, data: Data(count: 1_000), parameterSets: [],
                                 codec: .hevc, width: 320, height: 180)

        // Over a second's worth at 2 Mbps: the delta is skipped at once. Drained: the keyframe is asked for.
        link.addBacklogForTesting(400_000)
        share.handleEncoded(delta)
        link.addBacklogForTesting(-400_000)
        share.handleEncoded(delta)
        try await waitUntil("the keyframe follows the drain") { received.keyframeTimes.count >= 2 }
        let afterDrain = received.keyframeTimes[1]
        XCTAssertGreaterThan(afterDrain - paired, 0.4, "half a second after the keyframe the viewer paired with")
        viewer.close()
        await share.stop()
    }

    /// The drain's log line says when its keyframe goes, as a tester reads it (docs/testing.md item 19): "sending a
    /// keyframe" only when it goes at once, "the keyframe goes when the half-second limit is up (in N ms)" when the
    /// viewer's limit holds it. A skip over a second's worth at 2 Mbps, drained, asks for the keyframe; a second later
    /// on the rule's clock, with none gone out, it asks again, within the same moment on the limiter's: that one is
    /// held (`.at` after one forced at once, `.folded` after one held already). Before, both lines said "sending a
    /// keyframe".
    @MainActor
    func testTheDrainSaysWhenTheHalfSecondLimitHoldsItsKeyframe() async throws {
        let (share, source) = try await listeningShare()
        source.emit(frame: try stripedFrame())           // the only frame: the source is still from here on
        await drain()
        let clock = SharerClock()
        share.backlogClock = { clock.now }
        let (viewer, received, reader) = try await rawViewer(of: share)
        defer { reader.cancel() }
        let link = try XCTUnwrap(share.link)
        let delta = EncodedFrame(seq: 50, captureHostTimeNs: 1, isKey: false, data: Data(count: 1_000), parameterSets: [],
                                 codec: .hevc, width: 320, height: 180)
        let mark = LogMark()

        link.addBacklogForTesting(400_000)
        share.handleEncoded(delta)                        // over a second's worth: skipped, and the skip starts
        link.addBacklogForTesting(-400_000)
        share.handleEncoded(delta)                        // drained: the keyframe is asked for
        clock.now += BacklogPolicy.keyframeRetry
        share.handleEncoded(delta)                        // none went out within a second: asked for again
        try await waitUntil("the keyframe follows the drain") { received.keyframeTimes.count >= 2 }

        let lines = try mark.entries("share").map(\.composedMessage).filter { $0.contains("the send backlog drained after") }
        XCTAssertEqual(lines.count, 2, lines.joined(separator: "\n"))
        let held = try XCTUnwrap(lines.last)
        XCTAssertFalse(held.contains("sending a keyframe"), held)
        let wait = try XCTUnwrap(held.firstMatch(of: /; the keyframe goes when the half-second limit is up \(in (\d+) ms\)$/), held)
        XCTAssertLessThanOrEqual(try XCTUnwrap(Int(wait.1)), 500, held)
        viewer.close()
        await share.stop()
    }

    /// A new viewer's first keyframe is never held, while a viewer that comes back (the same address) shares the limit
    /// of its link before. Over a still source: a viewer pairs, pairs again at once, then another viewer (another
    /// address) takes over just after.
    @MainActor
    func testANewViewersFirstKeyframeIsAtOnceAndAReturningOneSharesTheLimit() async throws {
        let (share, source) = try await listeningShare()
        source.emit(frame: try stripedFrame())           // the only frame: the source is still from here on
        await drain()
        let (first, firstReceived, firstReader) = try await rawViewer(of: share)
        defer { firstReader.cancel() }
        let firstKeyframe = try XCTUnwrap(firstReceived.keyframeTimes.first)

        /// Pairs a viewer from `host` and returns when the sharer took it over and when its first keyframe came.
        func pair(from host: NWEndpoint.Host) async throws
            -> (link: NitidoLink.Link, tookOver: CFTimeInterval, keyframe: CFTimeInterval) {
            let count = share.connectionCount
            let hello = Hello(protocolVersion: protocolVersion, role: .view, name: "Viewer", pixelWidth: 0, pixelHeight: 0, scale: 2)
            let endpoint = NWEndpoint.hostPort(host: host, port: NWEndpoint.Port(rawValue: share.listeningPort!)!)
            let link = NitidoLink.Link.connect(to: endpoint, code: share.code, sharerName: share.name, hello: hello)
            let received = ReceivedFrames()
            let reader = Task { @MainActor in
                for await m in link.messages {
                    if case .videoFrame(let f) = m { received.frames.append(f); received.times.append(CACurrentMediaTime()) }
                }
            }
            defer { reader.cancel() }
            let deadline = CACurrentMediaTime() + 10
            while share.connectionCount == count {
                guard CACurrentMediaTime() < deadline else { XCTFail("the sharer never took the viewer over"); throw TimedOut() }
                try await Task.sleep(for: .milliseconds(2))
            }
            let tookOver = CACurrentMediaTime()
            try await waitUntil("the viewer from \(host) gets its keyframe") { !received.keyframeTimes.isEmpty }
            return (link, tookOver, received.keyframeTimes[0])
        }

        let again = try await pair(from: "127.0.0.1")
        XCTAssertGreaterThan(again.keyframe - firstKeyframe, 0.4, "the same viewer back at once waits out the half second")
        let other = try await pair(from: "::1")
        XCTAssertLessThan(other.keyframe - other.tookOver, 0.3, "another viewer's first keyframe goes at once")
        first.close(); again.link.close(); other.link.close()
        await share.stop()
    }

    /// A viewer back from the same address within half a second of its last forced keyframe waits for the limit
    /// (`KeyframeLimiter`), and the deltas encoded meanwhile are held back from it: frames it never sees, so they count
    /// as dropped, as on the drain path. A delta that was already in the encoder when it took over is not counted: that
    /// viewer was never going to see it.
    @MainActor
    func testDeltasHeldForAReturningViewerDuringTheHalfSecondCountAsDropped() async throws {
        let (share, source) = try await listeningShare()
        source.emit(frame: try stripedFrame())           // the only frame: the source is still from here on
        await drain()
        let (first, _, firstReader) = try await rawViewer(of: share)
        defer { firstReader.cancel() }
        let key = try await realKeyframe()
        let encoder = try XCTUnwrap(share.encoder)
        let inFlight = encoder.nextSeq                    // encoded before the takeover

        let count = share.connectionCount
        let hello = Hello(protocolVersion: protocolVersion, role: .view, name: "Viewer", pixelWidth: 0, pixelHeight: 0, scale: 2)
        let again = NitidoLink.Link.connect(to: peer(for: share).endpoint, code: share.code, sharerName: share.name, hello: hello)
        try await waitUntil("the sharer takes the returning viewer over") { share.connectionCount > count }
        let before = share.droppedFramesTotal
        func delta(_ seq: UInt32) -> EncodedFrame {
            EncodedFrame(seq: seq, captureHostTimeNs: 1, isKey: false, data: Data([0, 0, 0, 1, 2]), parameterSets: [],
                         codec: key.codec, width: key.width, height: key.height)
        }
        share.handleEncoded(delta(inFlight &- 1))         // in the encoder at the takeover
        for k in 0..<3 { share.handleEncoded(delta(encoder.nextSeq &+ UInt32(k))) }   // encoded after it, while the limit holds
        XCTAssertEqual(share.droppedFramesTotal - before, 3, "the three deltas encoded after the takeover are dropped frames")
        first.close(); again.close()
        await share.stop()
    }

    /// Spec 12: a resize sends a hello with the new size and scale. A connection the listener took before a resize is
    /// made with the hello of that moment, and may finish its handshake after it: at the takeover the sharer says its
    /// current size and scale again, so that viewer does not keep the old ones until the next resize. Here the listener
    /// is handed the old hello back, as a connection made before the resize would carry it.
    @MainActor
    func testAViewerWhoseHandshakeStraddlesAResizeHearsTheNewSize() async throws {
        let (share, source) = try await listeningShare()
        let advertiser = try XCTUnwrap(share.advertiser)
        source.emit(.started(pixelWidth: 640, pixelHeight: 360, scale: 1))
        await drain()
        advertiser.update(hello: Hello(protocolVersion: protocolVersion, role: .share, name: share.name,
                                       pixelWidth: 320, pixelHeight: 180, scale: 2))
        let hello = Hello(protocolVersion: protocolVersion, role: .view, name: "Viewer", pixelWidth: 0, pixelHeight: 0, scale: 2)
        let viewer = NitidoLink.Link.connect(to: peer(for: share).endpoint, code: share.code, sharerName: share.name, hello: hello)
        let received = ReceivedMessages()
        let reader = Task { @MainActor in for await m in viewer.messages { received.messages.append(m) } }
        defer { reader.cancel() }
        try await waitUntil("the viewer hears the current size") {
            received.messages.contains { if case .hello(let h) = $0 { return h.pixelWidth == 640 }; return false }
        }
        let last = received.messages.last { if case .hello = $0 { return true }; return false }
        guard case .hello(let h)? = last else { return XCTFail("no hello") }
        XCTAssertEqual(h.pixelWidth, 640); XCTAssertEqual(h.pixelHeight, 360); XCTAssertEqual(h.scale, 1)
        viewer.close()
        await share.stop()
    }

    /// With the codec loop on and a viewer connected, the encoder feeds both, so the loop's own keyframes reach the
    /// viewer too: a quality slider moved in short steps over a still source asks for one at every rest, and those go
    /// through the viewer's half-second limit like every other forced keyframe (spec 8), instead of a new encoder's
    /// keyframe every 150 ms.
    @MainActor
    func testTheLoopsKeyframesKeepTheViewersHalfSecondLimit() async throws {
        let (share, source) = try await listeningShare()
        source.emit(frame: try stripedFrame())           // the only frame: the source is still from here on
        await drain()
        let (viewer, received, reader) = try await rawViewer(of: share)
        defer { reader.cancel() }
        share.loopback = true
        try await waitUntil("the loop's encoder sends its keyframe") { received.keyframeTimes.count == 2 }
        try await Task.sleep(for: .milliseconds(600))    // past the half second after the pairing keyframe
        let before = received.keyframeTimes.count
        for step in 0..<5 {                              // five rests of 200 ms: each one past the 150 ms rest
            share.qualityMbps = Double(10 + step * 5)
            try await Task.sleep(for: .milliseconds(200))
        }
        try await Task.sleep(for: .milliseconds(600))
        let times = Array(received.keyframeTimes.dropFirst(before))
        XCTAssertFalse(times.isEmpty, "a rest still refreshes the picture")
        for (a, b) in zip(times, times.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b - a, 0.45, "keyframes half a second apart at least: \(times)")
        }
        XCTAssertLessThanOrEqual(times.count, 3, "at most one per half second over 1.6 s: \(times)")
        viewer.close()
        await share.stop()
    }

    /// The encoder's frames and failures reach the share through one mailbox, in the order VideoToolbox handed them over
    /// (`ShareModel.encoderOutput`): deltas go to the viewer in encode order, since one out of order would corrupt its
    /// picture until the next keyframe. Here they come from another thread, back to back, as VideoToolbox's queue
    /// calls them.
    @MainActor
    func testTheEncodersFramesReachTheViewerInTheOrderTheyWereEncoded() async throws {
        let (share, source) = try await listeningShare()
        source.emit(frame: try stripedFrame())
        await drain()
        let (viewer, received, reader) = try await rawViewer(of: share)
        defer { reader.cancel() }
        let encoder = try XCTUnwrap(share.encoder)
        let emit = try XCTUnwrap(encoder.onFrame)
        let key = try await realKeyframe()
        let start = received.frames.count
        let deltas = (0..<40).map { k in
            EncodedFrame(seq: 1_000 + UInt32(k), captureHostTimeNs: 1, isKey: false, data: Data([0, 0, 0, 1, UInt8(k)]),
                         parameterSets: [], codec: key.codec, width: key.width, height: key.height)
        }
        DispatchQueue.global(qos: .userInteractive).async { for f in deltas { emit(f) } }
        try await waitUntil("every delta reaches the viewer") { received.frames.count >= start + deltas.count }
        XCTAssertEqual(received.frames.dropFirst(start).map(\.seq), deltas.map(\.seq), "in encode order")
        viewer.close()
        await share.stop()
    }

    /// The connections still proving the code are capped: eight in all and three from one address. Each one is a TLS
    /// handshake the sharer runs against the current code, so without a cap a host could test many guesses at once
    /// before the sharer counted the ninth failure, and hold the listener with connections that never speak. One over
    /// the cap is let go at once and counts for nothing; a viewer from another address still pairs.
    @MainActor
    func testConnectionsStillProvingTheCodeAreCappedPerAddress() async throws {
        let (share, source) = try await listeningShare()
        source.emit(frame: try stripedFrame())
        await drain()
        let probes = (0..<4).map { _ in NWConnection(to: peer(for: share).endpoint, using: .tcp) }
        defer { probes.forEach { $0.cancel() } }
        probes.forEach { $0.start(queue: .main) }
        try await waitUntil("three probes wait to prove the code") { share.unpairedCount == 3 }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(share.unpairedCount, 3, "the fourth from the same address is let go at once")
        XCTAssertEqual(share.wrongCodeAttempts, 0)
        let (viewer, _, reader) = try await rawViewer(of: share, host: "::1")
        defer { reader.cancel() }
        XCTAssertTrue(share.isSending, "a viewer from another address pairs")
        viewer.close()
        await share.stop()
    }

    /// The cap itself: three from one address, eight in all.
    func testTheCapOnConnectionsProvingTheCode() {
        XCTAssertTrue(ShareModel.admitsUnpaired(from: "10.0.0.2", among: ["10.0.0.2", "10.0.0.2"]))
        XCTAssertFalse(ShareModel.admitsUnpaired(from: "10.0.0.2", among: ["10.0.0.2", "10.0.0.2", "10.0.0.2"]))
        XCTAssertTrue(ShareModel.admitsUnpaired(from: "10.0.0.3", among: ["10.0.0.2", "10.0.0.2", "10.0.0.2"]))
        let seven = (1...7).map { "10.0.0.\($0)" }
        XCTAssertTrue(ShareModel.admitsUnpaired(from: "10.0.0.9", among: seven))
        XCTAssertFalse(ShareModel.admitsUnpaired(from: "10.0.0.9", among: seven + ["10.0.0.8"]))
        XCTAssertFalse(ShareModel.admitsUnpaired(from: nil, among: [nil, nil, nil]), "no address counts as one")
    }

    /// A frame VideoToolbox drops that carried a keyframe request leaves the request standing (`VideoEncoder`). Over a
    /// still source no next frame comes to carry it, so the share encodes the newest frame again: the keyframe still
    /// reaches the viewer, rather than a viewer that took over or drained waiting for the content to move.
    @MainActor
    func testAKeyframeVideoToolboxDroppedFromAStillSourceStillReachesTheViewer() async throws {
        let (share, source) = try await listeningShare()
        source.emit(frame: try stripedFrame())           // the only frame: the source is still from here on
        await drain()
        let (viewer, received, reader) = try await rawViewer(of: share)
        defer { reader.cancel() }
        let encoder = try XCTUnwrap(share.encoder)
        let report = try XCTUnwrap(encoder.onError)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(received.keyframeTimes.count, 1)

        // As VideoToolbox drops a frame forced to be a keyframe: the request stands again, and the drop is reported.
        encoder.requestKeyframe()
        report(.frameDropped)
        try await waitUntil("the keyframe reaches the viewer all the same") { received.keyframeTimes.count == 2 }
        XCTAssertEqual(share.state, .capturing)
        viewer.close()
        await share.stop()
    }

    /// The same for a frame VideoToolbox fails in its callback (`.encode`): the keyframe request it carried stands for the
    /// next frame, and over a still source none comes, so the share encodes the newest frame again. The viewer's own
    /// ask after a decode failure has no second chance, so without this its picture would stay as it was until the
    /// content moved.
    @MainActor
    func testAKeyframeVideoToolboxFailedFromAStillSourceStillReachesTheViewer() async throws {
        let (share, source) = try await listeningShare()
        source.emit(frame: try stripedFrame())           // the only frame: the source is still from here on
        await drain()
        let (viewer, received, reader) = try await rawViewer(of: share)
        defer { reader.cancel() }
        let encoder = try XCTUnwrap(share.encoder)
        let report = try XCTUnwrap(encoder.onError)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(received.keyframeTimes.count, 1)

        // As VideoToolbox fails a frame forced to be a keyframe: the request stands again, and the failure is reported.
        encoder.requestKeyframe()
        report(.encode(-12902))
        try await waitUntil("the keyframe reaches the viewer all the same") { received.keyframeTimes.count == 2 }
        XCTAssertEqual(share.state, .capturing)
        viewer.close()
        await share.stop()
    }

    /// Spec 1 point 6 and spec 8: a viewer that takes over, or pairs again, has none of the frames the encoder's deltas in
    /// flight refer to (or only the one from before the drop), so it gets nothing before its keyframe: the deltas that
    /// were already in the encoder are held back, and the keyframe goes out with its setup.
    @MainActor
    func testANewViewerGetsNoDeltaBeforeItsKeyframe() async throws {
        let (share, _) = try await listeningShare()
        let key = try await realKeyframe()
        let hello = Hello(protocolVersion: protocolVersion, role: .view, name: "Viewer", pixelWidth: 0, pixelHeight: 0, scale: 2)
        let viewer = NitidoLink.Link.connect(to: peer(for: share).endpoint, code: share.code, sharerName: share.name, hello: hello)
        let received = ReceivedMessages()
        let reader = Task { @MainActor in for await m in viewer.messages { received.messages.append(m) } }
        defer { reader.cancel() }
        try await waitUntil("the sharer sends to the viewer") { share.isSending }
        // A delta still in the encoder when the viewer took over, then the keyframe the takeover asked for.
        share.handleEncoded(EncodedFrame(seq: 7, captureHostTimeNs: 1, isKey: false, data: Data([0, 0, 0, 1, 2]), parameterSets: [],
                                         codec: key.codec, width: key.width, height: key.height))
        share.handleEncoded(key)
        try await waitUntil("the keyframe reaches the viewer") {
            received.messages.contains { if case .videoFrame(let f) = $0 { return f.isKey }; return false }
        }
        let video = received.messages.filter { if case .videoConfig = $0 { return true }; if case .videoFrame = $0 { return true }; return false }
        XCTAssertEqual(video, [.videoConfig(try XCTUnwrap(key.videoConfig)), .videoFrame(key.videoFrame)], "the setup and the keyframe, no delta")
        XCTAssertEqual(share.snapshot.droppedLastSecond, 0, "a delta the viewer could not use is not a dropped frame")
        viewer.close()
        await share.stop()
    }

    /// The viewer's side of the same rule: once its link is ready (the first time or again), a delta that arrives before
    /// the keyframe never reaches the decoder, which would decode it against the frame from before the drop. It is
    /// neither a decode failure nor a dropped frame, and the keyframe after it is shown.
    @MainActor
    func testTheViewerDecodesNoDeltaBeforeItsKeyframe() async throws {
        let (share, _) = try await listeningShare()
        let key = try await realKeyframe()
        let viewer = ViewModel()
        let shown = ShownCounter(viewer.sink)
        viewer.select(peer(for: share))
        viewer.code = share.code
        viewer.connect()
        try await waitUntil("the viewer is connected") { viewer.state == .connected && share.isSending }
        viewer.handleIncoming(.videoConfig(try XCTUnwrap(key.videoConfig)))
        viewer.handleIncoming(.videoFrame(VideoFrame(seq: 1, captureHostTimeNs: 1, isKey: false, data: Data([0, 0, 0, 3, 1, 2, 3]))))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(viewer.decodeFailures, 0, "the delta never reached the decoder")
        viewer.handleIncoming(.videoFrame(key.videoFrame))
        try await waitUntil("the keyframe is shown") { shown.count >= 1 }
        try await Task.sleep(for: .milliseconds(300))    // the 250 ms loop publishes the figures
        XCTAssertEqual(viewer.snapshot.droppedLastSecond, 0)
        XCTAssertEqual(viewer.decodeFailures, 0)
        viewer.disconnect()
        await share.stop()
    }

    /// Spec 4: a viewer whose decoder falls behind drops work rather than queue it, and it judges behind by how long a
    /// frame has waited, not by how many wait. Four deltas handed over at once (the decoder's queue held here, as a
    /// stall would) all wait; 60 ms later the oldest has waited past 50 ms, so the next delta starts a skip to the next
    /// keyframe and the one after it is skipped too; the keyframe then drops the four that waited instead of decoding
    /// them first. Every one of the six never reaches the screen and counts as dropped, none is a decode failure, and
    /// the keyframe is shown. Spec 12: the skip is logged, once, with what was waiting.
    @MainActor
    func testAViewerThatFellBehindSkipsToTheKeyframeAndCountsWhatItDropped() async throws {
        let (share, _) = try await listeningShare()
        let key = try await realKeyframe()
        let viewer = ViewModel()
        let shown = ShownCounter(viewer.sink)
        viewer.select(peer(for: share))
        viewer.code = share.code
        viewer.connect()
        try await waitUntil("the viewer is connected") { viewer.state == .connected && share.isSending }
        viewer.handleIncoming(.videoConfig(try XCTUnwrap(key.videoConfig)))
        // Numbered one after another, so no gap counts as dropped; the deltas are never decoded, so any bytes do.
        func frame(_ seq: UInt32, isKey: Bool) -> VideoFrame {
            VideoFrame(seq: seq, captureHostTimeNs: 1, isKey: isKey, data: isKey ? key.data : Data([0, 0, 0, 3, 1, 2, 3]))
        }
        viewer.handleIncoming(.videoFrame(frame(0, isKey: true)))
        try await waitUntil("the first keyframe is shown") { shown.count == 1 }
        let decoder = try XCTUnwrap(viewer.decoder)
        decoder.drainForTesting()
        let mark = LogMark()
        decoder.suspendForTesting()
        for seq in 1...4 { viewer.handleIncoming(.videoFrame(frame(UInt32(seq), isKey: false))) }   // a burst: all four wait
        try await Task.sleep(for: .milliseconds(60))
        for seq in 5...6 { viewer.handleIncoming(.videoFrame(frame(UInt32(seq), isKey: false))) }   // skipped
        viewer.handleIncoming(.videoFrame(frame(7, isKey: true)))
        decoder.resumeForTesting()
        try await waitUntil("the keyframe after the skip is shown") { shown.count == 2 }
        try await waitUntil("the six frames count as dropped") { viewer.snapshot.droppedLastSecond == 6 }
        XCTAssertEqual(viewer.decodeFailures, 0, "no delta reached the decoder")
        let skips = try mark.entries("view").filter { $0.composedMessage.contains("keyframe") && $0.composedMessage.contains("behind") }
        XCTAssertEqual(skips.count, 1, "one line for the skip: \(skips.map(\.composedMessage))")
        XCTAssertEqual(skips.first?.level, .info)
        let line = try XCTUnwrap(skips.first?.composedMessage)
        let prefix = "the video decoder fell behind with 4 frames waiting, the oldest for "
        let suffix = " ms; skipping to the next keyframe"
        XCTAssertTrue(line.hasPrefix(prefix) && line.hasSuffix(suffix), line)
        let waited = Double(line.dropFirst(prefix.count).dropLast(suffix.count))
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(waited, "a figure in ms: \(line)"), 60, "the oldest waited through the 60 ms")
        viewer.disconnect()
        await share.stop()
    }

    /// The two-Mac test: the viewer's main thread fell behind the decoder (it presented 33 frames a second of 58), and
    /// every decoded frame waited for it in the main queue with its pixel buffer. Here the main thread is held for half
    /// a second while 29 frames reach the decoder at 58 fps: the decoder keeps up (nothing is skipped), and once the
    /// main thread runs again the view, in a window on screen (`ShowingDisplay`), gets one frame, the newest, and the 28
    /// decoded before it count as dropped without ever reaching the view.
    @MainActor
    func testAViewerWhoseMainThreadStallsGetsOnlyTheNewestDecodedFrame() async throws {
        let (share, _) = try await listeningShare()
        let frames = try await realFrames(30)
        let viewer = ViewModel()
        let view = VideoView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        let display = ShowingDisplay()
        display.show(view)
        viewer.sink.view = view
        viewer.select(peer(for: share))
        viewer.code = share.code
        viewer.connect()
        try await waitUntil("the viewer is connected") { viewer.state == .connected && share.isSending }
        viewer.handleIncoming(.videoConfig(try XCTUnwrap(frames[0].videoConfig)))
        viewer.handleIncoming(.videoFrame(frames[0].videoFrame))
        try await waitUntil("the keyframe is shown") { display.drawn.count == 1 }
        let decoder = try XCTUnwrap(viewer.decoder)
        decoder.drainForTesting()

        let deltas = frames[1...].map(\.videoFrame)
        let results = feedAtFiftyEightFpsWhileTheCallingThreadStalls(deltas, to: decoder)
        XCTAssertEqual(results, Array(repeating: .queued, count: deltas.count), "the decoder never fell behind")
        try await waitUntil("the stalled main thread hands the view the newest frame") {
            display.drawn.last == frames.last?.captureHostTimeNs
        }
        await drain()
        XCTAssertEqual(display.drawn.count, 2, "one frame after the stall, not one per decoded frame")
        try await waitUntil("the frames the newest replaced count as dropped") {
            viewer.snapshot.droppedLastSecond == deltas.count - 1
        }
        XCTAssertEqual(viewer.decodeFailures, 0)
        viewer.disconnect()
        await share.stop()
    }

    /// The same stall with no view to show the picture (the window not on screen yet, or gone): the frames the newest
    /// replaced are a pause, as every frame pushed then is (`.hidden`), not dropped frames. All 30 reach the sink as
    /// hidden, and the dropped figure stays at 0.
    @MainActor
    func testDecodedFramesReplacedWhileTheViewerHasNoViewAreAPauseNotDrops() async throws {
        let (share, _) = try await listeningShare()
        let frames = try await realFrames(30)
        let viewer = ViewModel()
        let hidden = ShownCounter(viewer.sink)
        XCTAssertNil(viewer.sink.view)
        viewer.select(peer(for: share))
        viewer.code = share.code
        viewer.connect()
        try await waitUntil("the viewer is connected") { viewer.state == .connected && share.isSending }
        viewer.handleIncoming(.videoConfig(try XCTUnwrap(frames[0].videoConfig)))
        viewer.handleIncoming(.videoFrame(frames[0].videoFrame))
        try await waitUntil("the keyframe reaches the sink") { hidden.count == 1 }
        let decoder = try XCTUnwrap(viewer.decoder)
        decoder.drainForTesting()

        let deltas = frames[1...].map(\.videoFrame)
        let results = feedAtFiftyEightFpsWhileTheCallingThreadStalls(deltas, to: decoder)
        XCTAssertEqual(results, Array(repeating: .queued, count: deltas.count))
        try await waitUntil("the newest frame and the 28 it replaced reach the sink as hidden") { hidden.count == frames.count }
        try await Task.sleep(for: .milliseconds(300))   // the 250 ms loop publishes the figures
        XCTAssertEqual(viewer.snapshot.droppedLastSecond, 0, "a pause, not dropped frames")
        XCTAssertEqual(viewer.decodeFailures, 0)
        viewer.disconnect()
        await share.stop()
    }

    /// `frameBytes`, the unit of the backlog rule, follows the rate the encoder runs at: a viewer that pairs starts from
    /// the initial rate for the picture's size, not from the cut-down rate a congested viewer before it left, and the
    /// codec loop's quality slider sets it while the loop is on.
    @MainActor
    func testTheBitrateStartsAfreshForEachViewerAndFollowsTheSlider() async throws {
        let (share, source) = try await listeningShare(width: 1920, height: 1080)
        source.emit(frame: try stripedFrame(width: 1920, height: 1080))
        await drain()
        let sharer = peer(for: share)
        let initialFrameBytes = BitrateController.initialBitrate(width: 1920, height: 1080) / 8 / 60
        let first = ViewModel()
        first.select(sharer)
        first.code = share.code
        first.connect()
        try await waitUntil("the first viewer is connected") { first.state == .connected && share.isSending }
        try await waitUntil("the encoder runs at the initial rate") { share.frameBytes == initialFrameBytes }

        // Congested: the 250 ms loop cuts the rate by a quarter.
        let link = try XCTUnwrap(share.link)
        let congestion = 40 * initialFrameBytes
        link.addBacklogForTesting(congestion)
        try await waitUntil("the controller cuts the rate") { share.frameBytes < initialFrameBytes }
        link.addBacklogForTesting(-congestion)

        let second = ViewModel()
        second.select(sharer)
        second.code = share.code
        second.connect()
        try await waitUntil("the second viewer takes over") { second.state == .connected && share.link !== link }
        XCTAssertEqual(share.frameBytes, initialFrameBytes, "a new viewer starts from the initial rate")

        share.loopback = true
        XCTAssertEqual(share.frameBytes, Int(share.qualityMbps * 1_000_000) / 8 / 60,
                       "the loop turned on runs at the slider's rate before the slider moves")
        share.qualityMbps = 60
        XCTAssertEqual(share.frameBytes, 60_000_000 / 8 / 60, "the slider's rate sizes a frame while the loop is on")
        second.disconnect(); first.disconnect()
        await share.stop()
    }

    /// Spec 1 allows connecting a viewer, then turning the codec loop on: the loop's picture and the strip's bitrate then
    /// show the slider's rate (20 Mbps by default), not the rate the controller had set for the viewer (2 Mbps for this
    /// 320x180 picture), which the loop would otherwise keep until the slider moved. A new encoder takes the slider's
    /// rate, so the loop's still picture shows it at once.
    @MainActor
    func testTheCodecLoopTurnedOnWithAViewerConnectedRunsAtTheSlidersRate() async throws {
        let (share, source) = try await listeningShare()
        source.emit(frame: try stripedFrame())
        await drain()
        let (viewer, received, reader) = try await rawViewer(of: share)
        defer { reader.cancel() }
        XCTAssertEqual(share.frameBytes, BitrateController.initialBitrate(width: 320, height: 180) / 8 / 60)
        let keyframes = received.keyframeTimes.count

        share.loopback = true
        XCTAssertEqual(share.frameBytes, Int(share.qualityMbps * 1_000_000) / 8 / 60, "the loop runs at the slider's rate")
        try await waitUntil("the viewer gets the new encoder's keyframe") { received.keyframeTimes.count > keyframes }
        XCTAssertEqual(share.state, .capturing)
        viewer.close()
        await share.stop()
    }

    /// Pongs held up behind a queue are the congestion the RTT measures, so the controller hears about it while the
    /// pong is still on its way: the oldest ping still waiting for its pong counts as an RTT that long. Before, every
    /// 250 ms update repeated the last pong's RTT, so a stalled link read as healthy until the pongs came back (and could
    /// even raise the rate). Here the viewer stops answering pings: the rate is cut within a second, before the link's
    /// three seconds without a pong fail it.
    @MainActor
    func testPongsThatStallCutTheRateBeforeTheyComeBack() async throws {
        let (share, source) = try await listeningShare(width: 1920, height: 1080)
        source.emit(frame: try stripedFrame(width: 1920, height: 1080))
        await drain()
        let (viewer, _, reader) = try await rawViewer(of: share)
        defer { reader.cancel() }
        let initialFrameBytes = BitrateController.initialBitrate(width: 1920, height: 1080) / 8 / 60
        try await Task.sleep(for: .milliseconds(1_200))  // pongs give the controller its baseline RTT
        XCTAssertGreaterThanOrEqual(share.frameBytes, initialFrameBytes)
        let rate = share.frameBytes
        viewer.muteForTesting()
        let muted = CACurrentMediaTime()
        try await waitUntil("the controller cuts the rate", timeout: 2.5) { share.frameBytes < rate }
        XCTAssertLessThan(CACurrentMediaTime() - muted, 1.5, "within a second or so of the pongs stalling")
        XCTAssertTrue(share.isSending, "before the link fails for want of pongs")
        viewer.close()
        await share.stop()
    }

    /// Three wrong codes mean someone is guessing: the sharer shows a new code and listens with its key, the old code no
    /// longer pairs, and the viewer who had paired goes on as it was. One attempt that fails the handshake several times
    /// in a row from one address (on two Macs, most likely Network.framework trying each address of the sharer) is one
    /// wrong code, so
    /// the guesses here come seconds apart on the sharer's clock.
    @MainActor
    func testThreeFailedHandshakesRotateTheCodeAndLeaveTheViewerAlone() async throws {
        let (share, source) = try await listeningShare()
        source.emit(frame: try stripedFrame())
        await drain()
        let viewer = ViewModel()
        let shown = ShownCounter(viewer.sink)
        let sharer = peer(for: share)
        viewer.select(sharer)
        viewer.code = share.code
        viewer.connect()
        try await waitUntil("the viewer shows the picture") { viewer.state == .connected && shown.count >= 1 }
        let original = share.code, listener = try XCTUnwrap(share.advertiser)
        let clock = SharerClock()
        share.handshakeClock = { clock.now }
        let hello = Hello(protocolVersion: protocolVersion, role: .view, name: "Guess", pixelWidth: 0, pixelHeight: 0, scale: 2)
        func guess(_ i: Int) async throws {
            let wrong = String(format: "%04d", (Int(original)! + i) % 10_000)
            let guess = NitidoLink.Link.connect(to: sharer.endpoint, code: wrong, sharerName: sharer.keyName, hello: hello)
            try await waitUntil("guess \(i) fails") { if case .failed = guess.state { return true }; return false }
            try await waitUntil("the sharer lets guess \(i) go") { share.unpairedCount == 0 }
        }
        for _ in 1...4 { try await guess(1) }
        XCTAssertEqual(share.wrongCodeAttempts, 1, "four failed handshakes from one address within the window are one attempt")
        for i in 2...3 {
            XCTAssertEqual(share.code, original, "the code holds before the third wrong code (attempt \(i))")
            clock.now += 3.5
            try await guess(i)
        }
        XCTAssertNotEqual(share.code, original, "three wrong codes rotate the code")
        XCTAssertFalse(share.advertiser === listener, "the new code listens with its own key")
        try await waitUntil("the new listener is ready") { share.listeningPort != nil }

        // The viewer who had paired goes on: the stopped listener does not end its connection.
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(viewer.state, .connected)
        XCTAssertTrue(share.isSending)
        let before = shown.count
        source.emit(frame: try stripedFrame(index: 1))
        try await waitUntil("a new frame still reaches the viewer") { shown.count > before }

        // The old code fails against the new listener; the new one pairs.
        let renewed = peer(for: share)
        let stale = ViewModel()
        stale.select(renewed)
        stale.code = original
        stale.connect()
        try await waitUntil("the old code no longer pairs") {
            stale.wrongCodeCount == 1 && stale.state == .enteringCode(renewed)
        }
        let next = ViewModel()
        next.select(renewed)
        next.code = share.code
        next.connect()
        try await waitUntil("the new code pairs") { next.state == .connected }
        next.disconnect(); stale.disconnect(); viewer.disconnect()
        await share.stop()
    }

    /// A rotation lets go of the connections still in their handshake on the old listener: they were made for the old
    /// code, which no longer pairs, so none of them can pair or count against the new code later. Counting starts again
    /// from nothing: the first wrong code against the new code counts, even right after the change from the same address.
    @MainActor
    func testARotationLetsGoOfTheOldListenersHandshakesAndCountsAfresh() async throws {
        let (share, _) = try await listeningShare()
        let original = share.code, sharer = peer(for: share)
        let clock = SharerClock()
        share.handshakeClock = { clock.now }
        let hello = Hello(protocolVersion: protocolVersion, role: .view, name: "Guess", pixelWidth: 0, pixelHeight: 0, scale: 2)
        // A wrong code for the code the sharer shows now; the sharer lets it go, leaving `open` connections unproved.
        func guess(_ i: Int, at endpoint: NWEndpoint, leaving open: Int) async throws {
            let wrong = String(format: "%04d", (Int(share.code)! + i) % 10_000)
            let guess = NitidoLink.Link.connect(to: endpoint, code: wrong, sharerName: share.name, hello: hello)
            try await waitUntil("guess \(i) fails") { if case .failed = guess.state { return true }; return false }
            // Well within the 8 s a sharer gives an unproved connection: only the rotation can let the held one go here.
            try await waitUntil("the sharer lets guess \(i) go, leaving \(open)", timeout: 2) { share.unpairedCount == open }
        }

        // A connection that never finishes its handshake: held by the old listener, apart from any viewer.
        let held = NWConnection(to: sharer.endpoint, using: .tcp)
        held.start(queue: DispatchQueue(label: "held"))
        defer { held.cancel() }
        try await waitUntil("the sharer holds the connection") { share.unpairedCount == 1 }
        for i in 1...2 {
            try await guess(i, at: sharer.endpoint, leaving: 1)
            clock.now += 3.5
        }
        XCTAssertEqual(share.wrongCodeAttempts, 2)
        try await guess(3, at: sharer.endpoint, leaving: 0)
        XCTAssertNotEqual(share.code, original, "three wrong codes rotate the code")
        XCTAssertEqual(share.unpairedCount, 0, "the old listener's handshakes are let go with it")
        XCTAssertEqual(share.wrongCodeAttempts, 0)

        // The same address at the same moment on the sharer's clock: a new attempt, the first against the new code.
        try await waitUntil("the new listener is ready") { share.listeningPort != nil }
        try await guess(4, at: peer(for: share).endpoint, leaving: 0)
        XCTAssertEqual(share.wrongCodeAttempts, 1, "the first wrong code against the new code counts")
        await share.stop()
    }

    /// A connection the old listener took and put in its stream just before the code changed reaches the share's loop
    /// after the change. It is let go there, whatever its handshake did by then: it neither pairs with the old code nor
    /// fails and counts against the new one. A listener of the test's own, with the old code, stands in for the old
    /// listener's handshakes, so both have run before the share takes the connections.
    @MainActor
    func testAConnectionTheRetiredListenerTookIsLetGoWithoutPairingOrCounting() async throws {
        let (share, _) = try await listeningShare()
        let original = share.code
        let retired = try XCTUnwrap(share.advertiser)
        let standIn = try Advertiser(name: share.name, code: original,
                                     hello: Hello(protocolVersion: protocolVersion, role: .share, name: share.name,
                                                  pixelWidth: 320, pixelHeight: 180, scale: 2))
        let port = try await standIn.start()
        defer { standIn.stop() }
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let hello = Hello(protocolVersion: protocolVersion, role: .view, name: "Late", pixelWidth: 0, pixelHeight: 0, scale: 2)
        var taken = standIn.incoming.makeAsyncIterator()
        // One that proved the old code...
        let viewer = NitidoLink.Link.connect(to: endpoint, code: original, sharerName: share.name, hello: hello)
        defer { viewer.abort() }
        guard let proved = await taken.next() else { return XCTFail("no connection") }
        try await waitUntil("the old code pairs") { proved.state == .ready && viewer.state == .ready }
        // ...and one with a wrong code, which failed on the keys.
        let wrong = String(format: "%04d", (Int(original)! + 1) % 10_000)
        let guess = NitidoLink.Link.connect(to: endpoint, code: wrong, sharerName: share.name, hello: hello)
        defer { guess.abort() }
        guard let guessed = await taken.next() else { return XCTFail("no connection") }
        try await waitUntil("the wrong code fails") { if case .failed = guessed.state { return true }; return false }
        XCTAssertTrue(guessed.keyMismatch, "a wrong code, which would count")

        // Both are in the old listener's stream when the code changes; the share's loop takes them only after.
        retired.deliver(proved)
        retired.deliver(guessed)
        share.rotateCode()
        XCTAssertNotEqual(share.code, original)
        XCTAssertFalse(share.advertiser === retired)

        // The loop takes them as soon as the test lets the main actor go.
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(share.connectionCount, 0, "nothing paired with the old code")
        XCTAssertFalse(share.isSending)
        XCTAssertNil(share.viewerName)
        XCTAssertEqual(share.wrongCodeAttempts, 0, "a wrong code for the old code does not count against the new one")
        XCTAssertEqual(share.unpairedCount, 0)
        try await waitUntil("the share has let go of the one that proved the old code", timeout: 2) { proved.state == .cancelled }
        try await waitUntil("its viewer hears so", timeout: 2) { viewer.state != .ready }
        await share.stop()
    }

    /// Spec 12, "Link drops": both sides say Reconnecting. A viewer link that ends without `bye` (a cut network, a viewer
    /// that died) keeps the viewer's name in the sharer's pairing panel as reconnecting, until the viewer pairs again,
    /// or the grace period passes and the sharer goes back to waiting. A `bye` (Back) lets the viewer go at once.
    @MainActor
    func testTheSharerShowsAViewerThatDroppedAsReconnecting() async throws {
        let (share, source) = try await listeningShare()
        source.emit(frame: try stripedFrame())
        await drain()
        share.reconnectGrace = .milliseconds(600)
        let endpoint = peer(for: share).endpoint
        let hello = Hello(protocolVersion: protocolVersion, role: .view, name: "Viewer", pixelWidth: 0, pixelHeight: 0, scale: 2)
        func pair() async throws -> NitidoLink.Link {
            let link = NitidoLink.Link.connect(to: endpoint, code: share.code, sharerName: share.name, hello: hello)
            try await waitUntil("the viewer pairs") { share.isSending && share.viewerName == "Viewer" && !share.viewerReconnecting }
            return link
        }

        let first = try await pair()
        first.abort()                                    // gone without bye
        try await waitUntil("the sharer says the viewer is reconnecting") { share.viewerReconnecting }
        XCTAssertEqual(share.viewerName, "Viewer", "the viewer's name stays while it reconnects")
        XCTAssertFalse(share.isSending)

        let second = try await pair()                   // it comes back
        XCTAssertFalse(share.viewerReconnecting)
        second.abort()
        try await waitUntil("reconnecting again") { share.viewerReconnecting }
        try await waitUntil("the grace period ends and the sharer waits for a viewer") { !share.viewerReconnecting && share.viewerName == nil }

        let third = try await pair()
        third.close()                                    // Back: a bye
        try await waitUntil("a bye lets the viewer go at once") { share.viewerName == nil }
        XCTAssertFalse(share.viewerReconnecting)
        await share.stop()
    }

    /// Back on the viewer frees the sharer for the next viewer.
    @MainActor
    func testDisconnectEndsTheViewerOnTheSharer() async throws {
        let (share, _) = try await listeningShare()
        let viewer = ViewModel()
        viewer.select(peer(for: share))
        viewer.code = share.code
        viewer.connect()
        try await waitUntil("the sharer sends to the viewer") { share.isSending && share.viewerName != nil }
        viewer.disconnect()
        try await waitUntil("the sharer lets the viewer go") { !share.isSending && share.viewerName == nil }
        await share.stop()
    }

    /// A wrong code fails the handshake: the viewer goes straight back to the code for that Mac, where the field shakes
    /// and says "Wrong code" (`wrongCodeCount`), with the code typed kept to be corrected. Choosing a Mac starts the
    /// count again; the right code connects, and both ends count the connection (the gold ring's trigger).
    @MainActor
    func testAWrongCodeGoesBackToTheCodeForThatMacAndCountsIt() async throws {
        let (share, _) = try await listeningShare()
        let viewer = ViewModel()
        let sharer = peer(for: share)
        viewer.select(sharer)
        let wrong = String(format: "%04d", (Int(share.code)! + 1) % 10_000)
        viewer.code = wrong
        viewer.connect()
        try await waitUntil("the viewer is back on the code for that Mac") { viewer.wrongCodeCount == 1 }
        XCTAssertEqual(viewer.state, .enteringCode(sharer))
        XCTAssertEqual(viewer.code, wrong, "the code typed stays, to be corrected")
        viewer.connect()
        try await waitUntil("a second wrong code counts again") { viewer.wrongCodeCount == 2 }
        XCTAssertEqual(viewer.state, .enteringCode(sharer))
        XCTAssertEqual(viewer.connectionCount, 0)
        XCTAssertEqual(share.connectionCount, 0, "a connection that never proved the code is no connection")

        viewer.disconnect()
        viewer.select(sharer)
        XCTAssertEqual(viewer.wrongCodeCount, 0, "choosing a Mac starts the count again")
        viewer.code = share.code
        viewer.connect()
        try await waitUntil("the right code connects") { viewer.state == .connected && share.isSending }
        XCTAssertEqual(viewer.connectionCount, 1)
        XCTAssertEqual(share.connectionCount, 1)
        viewer.disconnect()
        await share.stop()
    }

    /// Two Macs, wrong code: the viewer said "No answer from the other Mac within 15 seconds" when it connected to the
    /// Bonjour service, most likely because Network.framework tried its several addresses one after another without a
    /// word. It now
    /// connects to the address the sharer published (here the loopback address, behind a Bonjour service that never
    /// resolves), and the failed handshake comes back at once as "Wrong code", one wrong code on the sharer. The right
    /// code pairs the same way.
    @MainActor
    func testAWrongCodeThroughThePublishedAddressSaysWrongCodeAtOnce() async throws {
        let (share, _) = try await listeningShare()
        let viewer = ViewModel()
        let absent = NWEndpoint.service(name: "Absent \(UInt32.random(in: 0..<1_000_000))", type: "_nitido._tcp", domain: "local.", interface: nil)
        let sharer = Peer(id: "published", name: share.name, keyName: share.name, endpoint: absent,
                          addresses: [IPv4Address("127.0.0.1")!], port: try XCTUnwrap(share.listeningPort))
        viewer.select(sharer)
        viewer.code = String(format: "%04d", (Int(share.code)! + 1) % 10_000)
        let started = CACurrentMediaTime()
        viewer.connect()
        try await waitUntil("the viewer says Wrong code", timeout: 5) { viewer.wrongCodeCount == 1 }
        XCTAssertLessThan(CACurrentMediaTime() - started, 2, "the failed handshake came back at once")
        XCTAssertEqual(viewer.state, .enteringCode(sharer))
        try await waitUntil("the sharer lets the attempt go") { share.unpairedCount == 0 }
        XCTAssertEqual(share.wrongCodeAttempts, 1, "one wrong code on the sharer")

        viewer.code = share.code
        viewer.connect()
        try await waitUntil("the right code connects") { viewer.state == .connected && share.isSending }
        viewer.disconnect()
        await share.stop()
    }

    /// A sharer whose code rotated listens on a new port and publishes it; the viewer chose it from the list before. It
    /// connects with what discovery says now: the new code goes to the new port first, not to the refused old one, and
    /// pairs at once (through the old port it would end on the Bonjour service, which never resolves here).
    @MainActor
    func testTheViewerConnectsWithWhatDiscoverySaysNow() async throws {
        let (share, _) = try await listeningShare()
        let port = try XCTUnwrap(share.listeningPort)
        let absent = NWEndpoint.service(name: "Absent \(UInt32.random(in: 0..<1_000_000))", type: "_nitido._tcp", domain: "local.", interface: nil)
        // Port 1: nothing listens there, as nothing does on the port of a listener stopped by a rotation.
        let chosen = Peer(id: "rotated", name: share.name, keyName: share.name, endpoint: absent, addresses: [IPv4Address("127.0.0.1")!], port: 1)
        let now = Peer(id: "rotated", name: share.name, keyName: share.name, endpoint: absent, addresses: [IPv4Address("127.0.0.1")!], port: port)
        let other = Peer(id: "other", name: "Other", keyName: "Other", endpoint: absent)
        XCTAssertEqual(ViewModel.latest(chosen, in: [other]), chosen, "gone from the list: as it was chosen")

        let viewer = ViewModel()
        viewer.select(chosen)
        viewer.peers = [other, now]
        viewer.code = share.code
        let mark = LogMark()
        let started = CACurrentMediaTime()
        viewer.connect()
        try await waitUntil("the viewer pairs through the new port", timeout: 5) { viewer.state == .connected && share.isSending }
        XCTAssertLessThan(CACurrentMediaTime() - started, 2)
        let tried = try mark.entries("session").map(\.composedMessage).filter { $0.hasPrefix("trying ") }
        XCTAssertEqual(tried, ["trying 127.0.0.1:\(port) (route 1 of 2)"], "the new port first, and no other try")
        viewer.disconnect()
        await share.stop()
    }

    /// A Mac that has just stopped sharing refuses the connection, and a refusal says nothing about the code: the viewer
    /// shows a failure screen with the reason instead of "Wrong code", the field does not shake (`wrongCodeCount` stays
    /// 0), and Try again goes back to the code for that Mac with the code kept.
    @MainActor
    func testAMacThatRefusesTheConnectionFailsWithTheReasonNotWrongCode() async throws {
        let viewer = ViewModel()
        // Nothing listens on loopback port 1: refused, as a stale Bonjour peer is.
        let gone = Peer(id: "gone", name: "Gone", keyName: "Gone", endpoint: .hostPort(host: "127.0.0.1", port: 1))
        viewer.select(gone)
        viewer.code = "1234"
        viewer.connect()
        XCTAssertEqual(viewer.state, .connecting(gone))
        // The link gives a refused connection its waiting timeout (5 s) before it fails.
        try await waitUntil("the viewer stops connecting", timeout: 15) { viewer.state != .connecting(gone) }
        guard case .failed(let text, let peer) = viewer.state else {
            return XCTFail("expected .failed, got \(viewer.state)")
        }
        // One sentence that names the Mac; Network.framework's own words ("The operation couldn't be completed.
        // (Network.NWError error 61 - Connection refused)") stay in the log.
        XCTAssertEqual(text, "Gone is no longer sharing.")
        XCTAssertFalse(text.contains("NWError"), text)
        XCTAssertEqual(peer, gone)
        XCTAssertEqual(viewer.wrongCodeCount, 0, "a refused connection is not a wrong code")
        XCTAssertEqual(viewer.connectionCount, 0)
        viewer.retry()
        XCTAssertEqual(viewer.state, .enteringCode(gone))
        XCTAssertEqual(viewer.code, "1234", "the code typed stays")
        viewer.disconnect()
    }

    /// Esc while connected asks first ("Disconnect?"): `escape()` raises the confirmation and leaves the viewer
    /// connected; only the confirmed stop lets it go. With nothing connected Esc stops at once (`AppModelTests`).
    @MainActor
    func testEscapeWhileConnectedAsksBeforeDisconnecting() async throws {
        let (share, _) = try await listeningShare()
        let app = AppModel()
        app.startView()
        let viewer = try XCTUnwrap(app.view)
        viewer.select(peer(for: share))
        viewer.code = share.code
        viewer.connect()
        try await waitUntil("the viewer is connected") { viewer.state == .connected && share.isSending }
        app.escape()
        await drain()
        XCTAssertTrue(app.confirmStop, "Esc asks before it disconnects")
        XCTAssertEqual(app.stopQuestion, "Disconnect?", "only the viewer is live")
        XCTAssertEqual(app.screen, .view)
        XCTAssertTrue(app.view === viewer)
        XCTAssertEqual(viewer.state, .connected)
        await app.stop()
        XCTAssertEqual(app.screen, .welcome)
        XCTAssertNil(app.view)
        try await waitUntil("the sharer lets the viewer go") { !share.isSending && share.viewerName == nil }
        await share.stop()
    }

    /// ⌘Q (or closing the window, which quits the app) while a viewer is connected: the quit waits (`shouldQuitNow`
    /// answers false) until the viewer has stopped and its `bye` is out, so the sharer hears a goodbye (the link ends
    /// as `.cancelled` with reason `ended`) instead of a dropped connection it would wait on, and only then quits.
    @MainActor
    func testQuitWhileConnectedSaysByeBeforeQuitting() async throws {
        let advertiser = try Advertiser(name: "Sharer", code: "1234",
                                        hello: Hello(protocolVersion: protocolVersion, role: .share, name: "Sharer", pixelWidth: 320, pixelHeight: 180, scale: 2))
        let port = try await advertiser.start()
        defer { advertiser.stop() }
        let sharer = Peer(id: "loopback", name: "Sharer", keyName: "Sharer", endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!))
        let app = AppModel()
        app.startView()
        let viewer = try XCTUnwrap(app.view)
        viewer.select(sharer)
        viewer.code = "1234"
        viewer.connect()
        var incoming = advertiser.incoming.makeAsyncIterator()
        guard let sharerSide = await incoming.next() else { return XCTFail("no connection") }
        try await waitUntil("the viewer is connected") { viewer.state == .connected }

        var quits = 0
        XCTAssertFalse(app.shouldQuitNow { quits += 1 }, "a live session stops before the app quits")
        XCTAssertEqual(quits, 0)
        try await waitUntil("the app quits once the session has stopped", timeout: 3) { quits == 1 }
        XCTAssertNil(app.view)
        XCTAssertEqual(app.screen, .welcome)
        var ended: NitidoLink.Link.State?
        for await s in sharerSide.states { ended = s }
        XCTAssertEqual(ended, .cancelled, "the sharer heard bye, not a dropped connection")
        XCTAssertEqual(sharerSide.byeReason, ByeReason.ended)
        try await Task.sleep(for: .milliseconds(2_200))
        XCTAssertEqual(quits, 1, "the deadline does not quit a second time")
    }

    /// A video setup the decoder cannot take fails the viewer and ends the link, so the sharer stops sending to it.
    @MainActor
    func testADecoderThatCannotStartEndsTheLink() async throws {
        let (share, _) = try await listeningShare()
        let viewer = ViewModel()
        viewer.select(peer(for: share))
        viewer.code = share.code
        viewer.connect()
        try await waitUntil("the sharer sends to the viewer") { share.isSending }
        viewer.handleIncoming(.videoConfig(VideoConfig(codec: .hevc, width: 320, height: 180, parameterSets: [Data([0, 1, 2])])))
        guard case .failed(let message, let peer) = viewer.state else { return XCTFail("expected a failure, got \(viewer.state)") }
        // Spec 9: one sentence, what happened and what to do; the log keeps the case (a setup it could not read).
        XCTAssertTrue(message.hasPrefix("The video decoder could not start (error "), message)
        XCTAssertTrue(message.hasSuffix("); reconnect to try again."), message)
        XCTAssertEqual(peer, self.peer(for: share), "Reconnect goes back to the same Mac")
        XCTAssertTrue(viewer.failureOffersReconnect)
        try await waitUntil("the sharer lets the viewer go") { !share.isSending && share.viewerName == nil }
        viewer.reconnect()
        try await waitUntil("Reconnect pairs again with the code typed") { viewer.state == .connected && share.isSending }
        viewer.disconnect()
        await share.stop()
    }

    /// The display scale in the sharer's hello comes from the peer: one that is not a real scale is not trusted.
    @MainActor
    func testAScaleThatIsNotADisplayScaleIsNotTrusted() {
        let viewer = ViewModel()
        for bad: Float in [.nan, .infinity, 0, -2, 1e9] {
            viewer.handleIncoming(.hello(Hello(protocolVersion: protocolVersion, role: .share, name: "Mac", pixelWidth: 640, pixelHeight: 360, scale: bad)))
            XCTAssertEqual(viewer.scale, 2, "scale \(bad)")
        }
        viewer.handleIncoming(.hello(Hello(protocolVersion: protocolVersion, role: .share, name: "Mac", pixelWidth: 640, pixelHeight: 360, scale: 1)))
        XCTAssertEqual(viewer.scale, 1)
    }

    /// Bonjour may show a sharer renamed ("Name (2)" for a second instance on the same Mac): the viewer pairs under the
    /// name the sharer keyed its listener with, not the one on the list, or the right code would fail as a wrong one.
    @MainActor
    func testTheViewerPairsWithARenamedSharerUnderItsKeyName() async throws {
        let (share, _) = try await listeningShare()
        let listed = peer(for: share)
        let renamed = Peer(id: listed.id, name: "\(share.name) (2)", keyName: share.name, endpoint: listed.endpoint)
        let viewer = ViewModel()
        viewer.select(renamed)
        viewer.code = share.code
        viewer.connect()
        try await waitUntil("the viewer pairs with the renamed sharer") { viewer.state == .connected && share.isSending }
        viewer.disconnect()
        await share.stop()
    }

    /// The right code typed on an Arabic keyboard ('١٢٣٤') pairs: the key is derived from ASCII digits, so the code is
    /// normalized before it is used, instead of failing as a wrong code and counting toward the sharer's rotation.
    @MainActor
    func testACodeTypedInArabicIndicDigitsPairs() async throws {
        let (share, _) = try await listeningShare()
        let viewer = ViewModel()
        viewer.select(peer(for: share))
        viewer.code = String(share.code.unicodeScalars.map { Character(UnicodeScalar(0x0660 + $0.value - 0x30)!) })
        XCTAssertNotEqual(viewer.code, share.code)
        viewer.connect()
        try await waitUntil("the viewer pairs") { viewer.state == .connected && share.isSending }
        XCTAssertEqual(viewer.wrongCodeCount, 0)
        XCTAssertEqual(viewer.code, share.code, "the field shows the code in ASCII digits")
        viewer.disconnect()
        await share.stop()
    }

    /// The pairing panel shows the name viewers see in their list: the one Bonjour registered, "Mac (2)" when another
    /// Mac already has the name, rather than the one the sharer asked for.
    @MainActor
    func testTheSharerKnowsTheNameBonjourRegisteredItUnder() async throws {
        let (share, _) = try await listeningShare()
        let advertiser = try XCTUnwrap(share.advertiser)
        try await waitUntil("the sharer learns its registered name") { share.advertisedName != nil }
        advertiser.registrationChanged(.add(.service(name: "Twin (2)", type: "_nitido._tcp", domain: "local.", interface: nil)))
        try await waitUntil("the sharer shows the name Bonjour gave it") { share.advertisedName == "Twin (2)" }
        await share.stop()
        XCTAssertNil(share.advertisedName, "a stopped share advertises nothing")
    }

    /// Connect does nothing until the code is four digits.
    @MainActor
    func testConnectNeedsFourDigits() async throws {
        let viewer = ViewModel()
        let sharer = Peer(id: "x", name: "Mac", keyName: "Mac", endpoint: .hostPort(host: "127.0.0.1", port: 9))
        viewer.select(sharer)
        viewer.code = "12"
        viewer.connect()
        XCTAssertEqual(viewer.state, .enteringCode(sharer))
    }

    /// Stopping a share while its listener comes up is a stop, not a network failure: the stopped share stays idle,
    /// and nothing is left waiting on the stopped listener. Round 0 stops before the listener's task has run (a
    /// listener started after its stop never answers), the later rounds a little later each time.
    @MainActor
    func testStoppingWhileTheListenerComesUpIsNotAFailureAndLeavesNothingWaiting() async throws {
        let sources = SourceFactory()
        let share = ShareModel(makeSource: sources.make, screenRecordingGranted: { true })
        for round in 0..<12 {
            share.start(excludingWindowIDs: [])
            try await waitUntil("session \(round) is made") { sources.made.count == round + 1 }
            sources.made[round].emit(.started(pixelWidth: 320, pixelHeight: 180, scale: 2))
            var spins = 0
            while share.advertiser == nil, spins < 10_000 { await Task.yield(); spins += 1 }
            weak let advertiser = share.advertiser
            XCTAssertNotNil(advertiser, "round \(round): the share listens once it captures")
            if round > 0 { try await Task.sleep(for: .microseconds(200 * round)) }
            await share.stop()
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertEqual(share.state, .idle, "round \(round)")
            XCTAssertNil(advertiser, "round \(round): the stopped listener is still held, waiting")
        }
    }

    /// A listener that dies after it started fails the share with Retry instead of leaving a share nobody can join;
    /// one that waits says why over the picture.
    @MainActor
    func testListenerTroubleIsShown() async throws {
        let (share, source) = try await listeningShare()
        let advertiser = try XCTUnwrap(share.advertiser)
        advertiser.listenerStateChanged(.waiting(.dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied))))
        try await waitUntil("the sharer shows why viewers cannot reach it") { share.networkNotice != nil }
        XCTAssertTrue(share.networkNotice?.contains("Local Network") == true, share.networkNotice ?? "")
        advertiser.listenerStateChanged(.failed(.posix(.EADDRINUSE)))
        try await waitUntil("the share fails") { if case .failed = share.state { return true }; return false }
        guard case .failed(let message) = share.state else { return }
        XCTAssertEqual(message, "Nítido stopped listening for viewers on the local network. Another app is using the network port Nítido listens on (error 48). Press Retry to listen again.")
        XCTAssertFalse(message.contains("NWError"), message)
        XCTAssertFalse(share.networkNotice?.contains("NWError") ?? false)
        // The stream, and the raw picture, go on until Retry, and the stream may report a new size meanwhile (a window
        // resized): the picture takes it, the failure stays, and nothing listens again. Only a capture that ended and
        // started again resumes a share without Retry.
        source.emit(.started(pixelWidth: 640, pixelHeight: 360, scale: 2))
        await drain()
        XCTAssertEqual(share.pixelSize, CGSize(width: 640, height: 360))
        XCTAssertEqual(share.state, .failed(message), "only Retry ends a listener failure")
        XCTAssertNil(share.advertiser)
        await share.stop()
    }

    /// Discovery that is denied or dies says so on the list instead of looking for Macs forever.
    @MainActor
    func testDiscoveryTroubleIsShown() async throws {
        // The real browser is not started: its own `.ready` could land after the state handed in and clear the notice.
        let viewer = ViewModel(startingDiscovery: false)
        viewer.browser.browserStateChanged(.waiting(.dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied))))
        try await waitUntil("the list shows that Local Network is off") { viewer.discoveryNotice?.contains("Local Network") == true }
        viewer.browser.browserStateChanged(.failed(.dns(DNSServiceErrorType(kDNSServiceErr_ServiceNotRunning))))
        try await waitUntil("the list shows that discovery stopped") { viewer.discoveryNotice?.contains("stopped") == true }
        XCTAssertEqual(viewer.discoveryNotice, "Nítido stopped looking for Macs. Bonjour, which finds Macs on the local network, is not working (error -65563). Press Esc, then View, to look again.")
    }
}
