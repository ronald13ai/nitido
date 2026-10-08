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

        let second = ViewModel()
        second.select(sharer)
        second.code = share.code
        second.connect()
        try await waitUntil("the second viewer is connected") { second.state == .connected }
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

    /// A decoder that keeps throwing is not a silent freeze on the viewer: each throw counts as a dropped frame, nine in
    /// a row leave the link up (a fresh keyframe may bring it back), the tenth ends the link and says so. A frame decoded
    /// in between starts the count again.
    @MainActor
    func testADecoderThatKeepsThrowingEndsTheLinkAfterTenInARow() async throws {
        let (share, _) = try await listeningShare()
        let viewer = ViewModel()
        viewer.select(peer(for: share))
        viewer.code = share.code
        viewer.connect()
        try await waitUntil("the viewer is connected") { viewer.state == .connected && share.isSending }
        let key = try await realKeyframe()
        viewer.handleIncoming(.videoConfig(try XCTUnwrap(key.videoConfig)))
        XCTAssertEqual(viewer.pixelSize, CGSize(width: 320, height: 180))
        // Real parameter sets built a decoder that works; this data is not a picture, so `decode` throws.
        let unreadable = VideoFrame(seq: 1, captureHostTimeNs: 1, isKey: true, data: Data([0, 0, 0, 3, 1, 2, 3]))
        for _ in 0..<9 { viewer.handleIncoming(.videoFrame(unreadable)) }
        XCTAssertEqual(viewer.state, .connected, "nine throws in a row leave the link up")
        viewer.handleIncoming(.videoFrame(key.videoFrame))
        for _ in 0..<9 { viewer.handleIncoming(.videoFrame(unreadable)) }
        XCTAssertEqual(viewer.state, .connected, "a frame decoded in between starts the count again")
        viewer.handleIncoming(.videoFrame(unreadable))
        XCTAssertEqual(viewer.state, .failed("Video decoding keeps failing.", nil))
        XCTAssertEqual(viewer.pixelSize, .zero)
        try await waitUntil("the strip counts every throw as dropped") { viewer.snapshot.droppedLastSecond >= 19 }
        try await waitUntil("the sharer lets the viewer go") { !share.isSending && share.viewerName == nil }
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

    /// A wrong code fails the handshake: the viewer says so, and Try again goes back to the code for that Mac.
    @MainActor
    func testWrongCodeSaysCouldNotConnectAndTryAgainKeepsTheMac() async throws {
        let (share, _) = try await listeningShare()
        let viewer = ViewModel()
        let sharer = peer(for: share)
        viewer.select(sharer)
        viewer.code = String(format: "%04d", (Int(share.code)! + 1) % 10_000)
        viewer.connect()
        try await waitUntil("the viewer reports the failed pairing") {
            viewer.state == .failed("Could not connect. Check the code and try again.", sharer)
        }
        viewer.retry()
        XCTAssertEqual(viewer.state, .enteringCode(sharer))
        await share.stop()
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
