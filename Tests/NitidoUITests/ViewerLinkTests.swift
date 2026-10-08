import XCTest
import AppKit
import SwiftUI
import Network
import CoreVideo
import QuartzCore
import dnssd
import NitidoCore
import NitidoCodec
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

/// Counts the decoded frames the viewer hands to its sink: with no view on screen each one is reported as hidden.
/// The viewer's own handler still runs first.
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

/// The video frames a plain viewer link received, in order.
@MainActor
private final class ReceivedFrames { var frames: [VideoFrame] = [] }

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
        let screen = try XCTUnwrap(NSScreen.main, "a screen to fit the picture on")
        guard screen.visibleFrame.width >= 560, screen.visibleFrame.height >= 540 else { throw XCTSkip("screen too small for 1:1") }
        XCTAssertEqual(viewer.fittedPointSize, CGSize(width: 500.5, height: 400.5))

        // On screen, as `ShareWindowSizeTests` checks the sharing side: the window takes the content's whole-point
        // size, and the picture sits at its top left with exactly the fitted size.
        _ = NSApplication.shared
        let controller = NSHostingController(rootView: ViewView(model: viewer))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 560, height: 360),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.contentViewController = nil }
        try await waitUntil("the viewer's video view exists") { viewer.sink.view != nil }
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

        // A mistyped code: the handshake fails.
        let wrong = String(format: "%04d", (Int(share.code)! + 1) % 10_000)
        let hello = Hello(protocolVersion: protocolVersion, role: .view, name: "Guess", pixelWidth: 0, pixelHeight: 0, scale: 2)
        let guess = NitidoLink.Link.connect(to: sharer.endpoint, code: wrong, sharerName: sharer.keyName, hello: hello)
        try await waitUntil("the wrong code fails") { if case .failed = guess.state { return true }; return false }
        try await waitUntil("the sharer lets the guess go") { share.unpairedCount == 0 }
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

        sources.made[0].emit(.failed("The user stopped the stream"))
        try await waitUntil("the share fails") { share.state == .failed("The user stopped the stream") }
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
        for _ in 0..<3 { viewer.handleIncoming(.videoFrame(unreadable)) }
        // The third throw let the decoder go: until the setup comes again, a keyframe decodes nothing and is no failure.
        viewer.handleIncoming(.videoFrame(key.videoFrame))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(shown.count, 0, "the third throw lets the decoder go")
        XCTAssertEqual(viewer.state, .connected)
        // Stands in for the sharer's answer to each keyframe request: a keyframe carries its setup (`videoConfig`).
        viewer.handleIncoming(.videoConfig(config))
        for _ in 0..<2 {
            for _ in 0..<3 { viewer.handleIncoming(.videoFrame(unreadable)) }
            viewer.handleIncoming(.videoConfig(config))
        }
        XCTAssertEqual(viewer.state, .connected, "nine throws in a row leave the link up")
        viewer.handleIncoming(.videoFrame(key.videoFrame))
        try await waitUntil("the fresh decoder shows the keyframe") { shown.count >= 1 }
        for _ in 0..<3 {
            for _ in 0..<3 { viewer.handleIncoming(.videoFrame(unreadable)) }
            viewer.handleIncoming(.videoConfig(config))
        }
        XCTAssertEqual(viewer.state, .connected, "a frame decoded in between starts the count again")
        viewer.handleIncoming(.videoFrame(unreadable))
        XCTAssertEqual(viewer.state, .failed("Video decoding keeps failing.", nil))
        XCTAssertEqual(viewer.pixelSize, .zero)
        try await waitUntil("the strip counts every throw as dropped") { viewer.snapshot.droppedLastSecond >= 19 }
        try await waitUntil("the sharer lets the viewer go") { !share.isSending && share.viewerName == nil }
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

    /// A sharer that died and came back with a new code (every launch makes one) turns the viewer's reconnect away in
    /// the handshake: the viewer asks for the new code instead of saying Reconnecting forever, which would also cost
    /// the sharer a failed handshake every few seconds and rotate its code under whoever is typing it.
    @MainActor
    func testAViewerWhoseSharerCameBackWithANewCodeAsksForIt() async throws {
        let sharerHello = Hello(protocolVersion: protocolVersion, role: .share, name: "Sharer", pixelWidth: 320, pixelHeight: 180, scale: 2)
        let first = try Advertiser(name: "Sharer", code: "1234", hello: sharerHello, port: 47_215)
        _ = try await first.start()
        let sharer = Peer(id: "loopback", name: "Sharer", keyName: "Sharer", endpoint: .hostPort(host: "127.0.0.1", port: 47_215))
        let viewer = ViewModel()
        viewer.select(sharer)
        viewer.code = "1234"
        viewer.connect()
        var incoming = first.incoming.makeAsyncIterator()
        guard let dropped = await incoming.next() else { return XCTFail("no connection") }
        try await waitUntil("the viewer is connected") { viewer.state == .connected }
        dropped.abort(); first.stop()                    // the sharer dies without bye...
        // ...and comes back on the same port with a new code, once the stopped listener has let the port go.
        var relaunched: Advertiser?
        for _ in 0..<40 where relaunched == nil {
            let advertiser = try Advertiser(name: "Sharer", code: "5678", hello: sharerHello, port: 47_215)
            do { _ = try await advertiser.start(); relaunched = advertiser } catch { advertiser.stop(); try await Task.sleep(for: .milliseconds(25)) }
        }
        guard let relaunched else { throw XCTSkip("port 47215 stayed in use") }
        let attempts = Task { () -> Int in var n = 0; for await _ in relaunched.incoming { n += 1 }; return n }
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

    /// Spec section 8: once frames are dropped for the send backlog, no delta goes out (it would refer to frames the
    /// viewer never got) until a keyframe has, and that keyframe follows as soon as the backlog drains under one frame,
    /// even from a source that went still and sends no frame that could check the drain.
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

        // Congested: more than four frames' worth waits to be sent, so deltas are skipped.
        let congestion = 20 * share.frameBytes
        link.addBacklogForTesting(congestion)
        for _ in 0..<3 { share.handleEncoded(delta) }
        try await Task.sleep(for: .milliseconds(400))    // the 250 ms loop runs, and sends no keyframe yet
        XCTAssertEqual(received.frames.count, sent, "nothing goes out while the backlog exceeds four frames")

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
        share.qualityMbps = 60
        XCTAssertEqual(share.frameBytes, 60_000_000 / 8 / 60, "the slider's rate sizes a frame while the loop is on")
        second.disconnect(); first.disconnect()
        await share.stop()
    }

    /// Three connections that fail to prove the code mean someone is guessing: the sharer shows a new code and listens
    /// with its key, the old code no longer pairs, and the viewer who had paired goes on as it was.
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
        let hello = Hello(protocolVersion: protocolVersion, role: .view, name: "Guess", pixelWidth: 0, pixelHeight: 0, scale: 2)
        for i in 1...3 {
            XCTAssertEqual(share.code, original, "the code holds before the third failed handshake (guess \(i))")
            let wrong = String(format: "%04d", (Int(original)! + i) % 10_000)
            let guess = NitidoLink.Link.connect(to: sharer.endpoint, code: wrong, sharerName: sharer.keyName, hello: hello)
            try await waitUntil("guess \(i) fails") { if case .failed = guess.state { return true }; return false }
            try await waitUntil("the sharer lets guess \(i) go") { share.unpairedCount == 0 }
        }
        XCTAssertNotEqual(share.code, original, "three failed handshakes rotate the code")
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
        XCTAssertTrue(text.hasPrefix("Could not connect to Gone. Could not reach the other Mac"), text)
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
        guard case .failed(let message, nil) = viewer.state else { return XCTFail("expected a failure, got \(viewer.state)") }
        XCTAssertTrue(message.hasPrefix("Could not start the video decoder"), message)
        try await waitUntil("the sharer lets the viewer go") { !share.isSending && share.viewerName == nil }
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
        let (share, _) = try await listeningShare()
        let advertiser = try XCTUnwrap(share.advertiser)
        advertiser.listenerStateChanged(.waiting(.dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied))))
        try await waitUntil("the sharer shows why viewers cannot reach it") { share.networkNotice != nil }
        XCTAssertTrue(share.networkNotice?.contains("Local Network") == true, share.networkNotice ?? "")
        advertiser.listenerStateChanged(.failed(.posix(.EADDRINUSE)))
        try await waitUntil("the share fails") { if case .failed = share.state { return true }; return false }
        guard case .failed(let message) = share.state else { return }
        XCTAssertTrue(message.contains("local network"), message)
        await share.stop()
    }

    /// Discovery that is denied or dies says so on the list instead of looking for Macs forever.
    @MainActor
    func testDiscoveryTroubleIsShown() async throws {
        let viewer = ViewModel()
        viewer.browser.browserStateChanged(.waiting(.dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied))))
        try await waitUntil("the list shows that Local Network is off") { viewer.discoveryNotice?.contains("Local Network") == true }
        viewer.browser.browserStateChanged(.failed(.dns(DNSServiceErrorType(kDNSServiceErr_ServiceNotRunning))))
        try await waitUntil("the list shows that discovery stopped") { viewer.discoveryNotice?.contains("stopped") == true }
    }
}
