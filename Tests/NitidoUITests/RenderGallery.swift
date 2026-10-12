import XCTest
import AppKit
import SwiftUI
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import QuartzCore
import CoreMedia
import ScreenCaptureKit
import Network
import dnssd
import NitidoCore
import NitidoTestSupport
@testable import NitidoCapture
@testable import NitidoLink
@testable import NitidoUI

/// The design review's gallery (spec 11): every screen state as a 2x PNG, without the system picker. Skipped unless
/// NITIDO_RENDER=1, so the suite never opens a window or writes a file:
///
///     NITIDO_RENDER=1 NITIDO_RENDER_DIR=/some/dir swift test --filter RenderGallery
///
/// Two kinds of picture. `offscreen-*` comes from SwiftUI's ImageRenderer (dark, scale 2), for what it draws faithfully:
/// the strip, the pairing panel, the buttons and the list of Macs. It draws no AppKit view (the picture, the ink, the
/// switch, the slider, the code field come out as a placeholder) and leaves out what sits on Liquid Glass over a backdrop
/// (the Welcome card comes out empty), so every other screen is `window-*`: a real window on screen captured with
/// `screencapture -l`, where Metal draws a synthetic desktop under the panels, the sharer is a real `ShareModel` fed by
/// a fake capture source and the viewer a real `ViewModel` paired with it over the loopback link, so the strip shows
/// measured figures. A test process cannot take activation from the app in front, so those windows draw their glass
/// and title bar as a window that is not key does: the sharer's usual case, since it works in the window it shares.
final class RenderGallery: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NITIDO_RENDER"] == "1", "set NITIDO_RENDER=1 to render the gallery")
        try FileManager.default.createDirectory(at: Gallery.directory, withIntermediateDirectories: true)
    }

    // MARK: Offscreen

    @MainActor
    func testOffscreenGallery() throws {
        FontLoader.registerBundledFonts()
        // ImageRenderer leaves out whatever sits on Liquid Glass until it has drawn a screen with glass on it once.
        let warmUp = stillShare()
        warmUp.state = .capturing
        _ = ImageRenderer(content: ShareView(model: warmUp).environment(\.colorScheme, .dark)).cgImage

        try offscreen("strip-calm", TelemetryStrip(snapshot: Self.calmSnapshot, resolution: "1440×900 @2x", codec: "HEVC",
                                                   latencyLabel: ShareView.latencyLabel, codecMs: 6).frame(width: 720))
        try offscreen("strip-over-threshold", TelemetryStrip(snapshot: Self.hotSnapshot, resolution: "2880×1800 @2x (75%)", codec: "H.264",
                                                             latencyLabel: ViewView.latencyLabel,
                                                             captureLabel: TelemetryStrip.Label.received).frame(width: 720))
        try offscreen("strip-empty", TelemetryStrip(snapshot: .empty, resolution: "·", codec: "raw",
                                                    latencyLabel: ShareView.latencyLabel).frame(width: 720))
        try offscreen("strip-wide-one-row", TelemetryStrip(snapshot: Self.calmSnapshot, resolution: "1440×900 @2x", codec: "HEVC",
                                                           latencyLabel: ShareView.latencyLabel, codecMs: 6).frame(width: 900))
        try offscreen("strip-wrapped-narrow", TelemetryStrip(snapshot: Self.calmSnapshot, resolution: "800×500 @2x", codec: "HEVC",
                                                             latencyLabel: ShareView.latencyLabel, codecMs: 6).frame(width: 400))
        try offscreen("pairing-panel-waiting", PairingPanel(name: "MacBook Pro de Ronald", code: "4827", viewer: nil,
                                                            connectionCount: 0, ringShownFor: .constant(0)).padding(24))
        try offscreen("pairing-panel-connected", PairingPanel(name: "MacBook Pro de Ronald", code: "4827", viewer: "Mac Studio de Ana",
                                                              connectionCount: 1, ringShownFor: .constant(1)).padding(24))
        try offscreen("pairing-panel-reconnecting", PairingPanel(name: "MacBook Pro de Ronald", code: "4827", viewer: "Mac Studio de Ana",
                                                                 reconnecting: true, connectionCount: 1, ringShownFor: .constant(1)).padding(24))
        try offscreen("buttons", VStack(spacing: 16) {
            HStack(spacing: 12) { GoldButton("Share") {}; QuietButton("View") {} }
            HStack(spacing: 12) { QuietButton("Back") {}; GoldButton("Connect") {}.disabled(true) }
        }.padding(24))

        // The list of Macs scrolls inside the canvas, and ImageRenderer draws nothing inside a scroll view: the list is in
        // the window gallery only (`view-browsing-*`).

        // A 200 by 100 px window shared at 2x: the picture sits centred in the minimum area, and the pairing panel and
        // the codec loop panel keep to it, side by side, the code whole.
        let tiny = stillShare()
        tiny.state = .capturing
        tiny.pixelSize = CGSize(width: 200, height: 100)
        try offscreen("share-tiny-window", ShareView(model: tiny))
        tiny.loopback = true
        try offscreen("share-tiny-window-loop-on", ShareView(model: tiny))
    }

    // MARK: Windows

    @MainActor
    func testWindowGallery() async throws {
        FontLoader.registerBundledFonts()
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.finishLaunching()
        try await pump(0.3)

        let welcome = Stage(WelcomeView(onShare: {}, onView: {}), at: CGPoint(x: 120, y: 260))
        try await welcome.capture("welcome", settle: 0.8)
        welcome.close()

        // The Share screen before a picture, and its permission failure: a model set by hand, no session.
        let still = stillShare()
        still.state = .picking
        still.mayAskForScreenRecording = true
        let stillStage = Stage(ShareView(model: still), at: CGPoint(x: 40, y: 200))
        try await stillStage.capture("share-picking-with-screen-recording-note")
        still.state = .failed(ShareModel.plainMessage(for: CaptureFailure(reason: .notPermitted, detail: "declined"), needsPermission: true))
        still.failureNeedsPermission = true
        try await stillStage.capture("share-failed-permission")
        stillStage.close()

        // A live share of a synthetic desktop, fed at 60 fps, with a fresh source for every session as the app makes one
        // (a retired session's streams have ended for good).
        let sources = PictureSources()
        let share = ShareModel(makeSource: { sources.make() }, screenRecordingGranted: { true })
        let dialog = DialogFlag()
        let shareStage = Stage(DialogHost(flag: dialog) { ShareView(model: share) }, at: CGPoint(x: 10, y: 330))
        share.start(excludingWindowIDs: [])
        try await shareStage.capture("share-picking")
        let pictures = try [Picture.desktop(width: 1440, height: 900, caret: true), Picture.desktop(width: 1440, height: 900, caret: false)]
        sources.current?.emit(.started(pixelWidth: 1440, pixelHeight: 900, scale: 2))
        try await waitUntil("the sharer listens") { share.listeningPort != nil }
        let feed = Task { @MainActor in
            var index = 0
            while !Task.isCancelled {
                sources.current?.emit(frame: CapturedFrame(pixelBuffer: pictures[index / 30 % 2], captureHostTimeNs: UInt64(CACurrentMediaTime() * 1e9),
                                                           contentRect: CGRect(x: 0, y: 0, width: 720, height: 450), scale: 2))
                index += 1
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
        defer { feed.cancel() }
        try await shareStage.capture("share-capturing-waiting-for-viewer", settle: 1.5)

        // The viewer: its list, the code, a wrong code, a Mac that never answers, then the share.
        let viewer = ViewModel(startingDiscovery: false)
        let viewStage = Stage(DialogHost(flag: dialog) { ViewView(model: viewer) }, at: CGPoint(x: 600, y: 120))
        try await viewStage.capture("view-browsing-empty")
        let sharer = Peer(id: "loopback", name: share.advertisedName ?? share.name, keyName: share.name,
                          endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: share.listeningPort!)!))
        // Eight Macs: the rows scroll inside the canvas, the last ones out of sight until scrolled to.
        viewer.peers = [sharer] + (2...8).map { Peer(id: "\($0)", name: "Mac \($0)", keyName: "Mac \($0)", endpoint: .hostPort(host: "127.0.0.1", port: 9)) }
        try await viewStage.capture("view-browsing-eight-peers")
        viewer.peers = [sharer, Self.twoPeers[1]]
        try await viewStage.capture("view-browsing-two-peers")
        viewer.select(sharer)
        try await viewStage.capture("view-code-empty")
        viewer.code = "48"
        try await viewStage.capture("view-code-typing")
        viewer.code = share.code == "0000" ? "1111" : "0000"
        viewer.connect()
        try await waitUntil("the sharer turns the code away") { viewer.wrongCodeCount == 1 }
        try await viewStage.capture("view-wrong-code", settle: 0.5)

        let silent = try SilentListener()
        let silentPort = try await silent.start()
        defer { silent.stop() }
        let mute = Peer(id: "silent", name: "Mac mini", keyName: "Mac mini",
                        endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: silentPort)!))
        viewer.select(mute)
        viewer.code = "1234"
        viewer.connect()
        try await viewStage.capture("view-connecting", settle: 0.4)
        viewer.disconnect()

        viewer.select(sharer)
        viewer.code = share.code
        viewer.connect()
        try await waitUntil("the viewer is connected") { viewer.state == .connected && share.viewerName != nil }
        try await viewStage.capture("view-connect-moment", settle: 0.15)
        try await viewStage.capture("view-connected", settle: 2)
        try await shareStage.capture("share-capturing-viewer-connected", settle: 0)

        // Ink both ways, and the sharer's cursor on the viewer.
        let mine = share.ink.beginLocal(StrokePoint(x: 0.58, y: 0.22, pressure: 1, tMs: 0))
        share.ink.appendLocal(mine, Self.scribble(from: CGPoint(x: 0.58, y: 0.22)))
        share.ink.endLocal(mine)
        share.ink.cursorMoved(Cursor(x: 0.74, y: 0.3, visible: true))
        let theirs = viewer.ink.beginLocal(StrokePoint(x: 0.36, y: 0.62, pressure: 1, tMs: 0))
        viewer.ink.appendLocal(theirs, Self.scribble(from: CGPoint(x: 0.36, y: 0.62)))
        viewer.ink.endLocal(theirs)
        try await viewStage.capture("view-connected-ink", settle: 0.6)
        try await shareStage.capture("share-ink", settle: 0)
        share.ink.clearLocal()

        viewer.showTelemetry = false
        try await viewStage.capture("view-connected-telemetry-hidden", settle: 0.3)
        viewer.showTelemetry = true

        share.loopback = true
        share.qualityMbps = 4
        share.dividerPosition = 0.42
        try await shareStage.capture("share-loopback-4mbps", settle: 1.5)
        share.loopback = false

        share.networkNotice = "Viewers cannot reach this Mac. \(NWError.localNetworkOff)"
        share.codecNotice = "The video encoder rejected its real-time setting (error -12900); the picture goes on without it."
        try await shareStage.capture("share-notices", settle: 0.5)
        share.networkNotice = nil
        share.codecNotice = nil

        // Esc's confirmation, the system's dialog.
        (dialog.question, dialog.action) = AppModel.stopWording(sharing: true, viewing: false)
        dialog.message = AppModel.stopMessage(sharing: true, viewing: false, viewer: share.viewerName, sharer: "")
        dialog.shown = true
        try await shareStage.captureSheet("dialog-stop-sharing", settle: 0.8)
        dialog.shown = false
        try await pump(0.5)

        // The capture stopped from the menu bar: Retry over the last picture, and the viewer is told.
        sources.current?.emit(.failed(CaptureFailure(reason: .stoppedFromMenuBar, detail: "stopped")))
        try await waitUntil("the viewer hears the share stopped") { if case .failed = viewer.state { return true }; return false }
        try await shareStage.capture("share-failed-over-last-picture", settle: 0.4)
        try await viewStage.capture("view-failed", settle: 0)

        // A link that drops without bye: the viewer keeps the last picture dimmed while it tries again, and the sharer's
        // panel says the viewer is reconnecting. The listener goes first, so the viewer's attempts keep failing.
        let sessions = sources.count
        share.retry()
        try await waitUntil("Retry opens a new session") { sources.count > sessions }
        sources.current?.emit(.started(pixelWidth: 1440, pixelHeight: 900, scale: 2))
        try await waitUntil("the sharer listens again") { share.state == .capturing && share.listeningPort != nil }
        let again = Peer(id: "loopback", name: share.name, keyName: share.name,
                         endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: share.listeningPort!)!))
        viewer.disconnect()
        viewer.peers = [again]
        viewer.select(again)
        viewer.code = share.code
        viewer.connect()
        try await waitUntil("the viewer is connected again") { viewer.state == .connected && share.viewerName != nil }
        try await pump(1)
        share.advertiser?.stop()
        share.link?.abort()
        try await waitUntil("the viewer reconnects") { if case .reconnecting = viewer.state { return true }; return false }
        try await viewStage.capture("view-reconnecting", settle: 0.6)
        try await shareStage.capture("share-viewer-reconnecting", settle: 0)
        (dialog.question, dialog.action) = AppModel.stopWording(sharing: false, viewing: true)
        dialog.message = AppModel.stopMessage(sharing: false, viewing: true, viewer: nil, sharer: viewer.sharerName)
        dialog.shown = true
        try await viewStage.captureSheet("dialog-disconnect", settle: 1.2)
        dialog.shown = false

        feed.cancel()
        viewer.disconnect()
        await share.stop()
        shareStage.close()
        viewStage.close()

        // Discovery off, and a sharer on another protocol version.
        let lonely = ViewModel(startingDiscovery: false)
        let lonelyStage = Stage(ViewView(model: lonely), at: CGPoint(x: 300, y: 300))
        lonely.browser.browserStateChanged(.waiting(.dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied))))
        try await waitUntil("the list says why it is empty") { lonely.discoveryNotice != nil }
        try await lonelyStage.capture("view-browsing-local-network-off")
        let newer = Hello(protocolVersion: protocolVersion + 1, role: .share, name: "Mac Studio", pixelWidth: 0, pixelHeight: 0, scale: 2)
        let advertiser = try Advertiser(name: "Mac Studio", code: "1234", hello: newer)
        let port = try await advertiser.start()
        defer { advertiser.stop() }
        let studio = Peer(id: "newer", name: "Mac Studio", keyName: "Mac Studio",
                          endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!))
        lonely.select(studio)
        lonely.code = "1234"
        lonely.connect()
        try await waitUntil("the viewer fails on the version") { if case .failed = lonely.state { return true }; return false }
        try await lonelyStage.capture("view-failed-protocol-version")
        lonely.disconnect()
        lonelyStage.close()
    }

    // MARK: Fixtures

    private static let twoPeers = [
        Peer(id: "a", name: "MacBook Pro de Ronald", keyName: "MacBook Pro de Ronald", endpoint: .hostPort(host: "127.0.0.1", port: 9)),
        Peer(id: "b", name: "Mac Studio de Ana", keyName: "Mac Studio de Ana", endpoint: .hostPort(host: "127.0.0.1", port: 9)),
    ]

    private static var calmSnapshot: Snapshot {
        var s = Snapshot.empty
        s.captureFPS = 60; s.displayFPS = 60; s.latencyMs = 34; s.latencyP95Ms = 41; s.rttMs = 3; s.bitrateMbps = 14.2
        s.warm = true
        s.latencySeries = (0..<40).map { 30 + 6 * sin(Double($0) / 3) + Double($0 % 7) }
        return s
    }

    private static var hotSnapshot: Snapshot {
        var s = calmSnapshot
        s.captureFPS = 48; s.displayFPS = 47; s.latencyMs = 132; s.rttMs = 41; s.bitrateMbps = 6.8; s.droppedLastSecond = 3
        s.latencySeries = (0..<40).map { 40 + Double($0) * 2.4 }
        return s
    }

    /// A wave across the picture, in normalized points after `start`.
    private static func scribble(from start: CGPoint) -> [StrokePoint] {
        (1...40).map { i in
            let t = Double(i) / 40
            return StrokePoint(x: Float(start.x + 0.16 * t), y: Float(start.y + 0.05 * sin(t * .pi * 3)), pressure: 1, tMs: UInt32(i * 12))
        }
    }

    /// A share with no session, for states set by hand.
    @MainActor
    private func stillShare() -> ShareModel { ShareModel(makeSource: { PictureSource() }, screenRecordingGranted: { true }) }

    /// Dark, at scale 2, laid on the background afterwards: given a backdrop, ImageRenderer leaves out whatever sits on
    /// Liquid Glass (the glass itself it never draws).
    @MainActor
    private func offscreen(_ name: String, _ view: some View) throws {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = 2
        guard let drawn = renderer.cgImage else { return XCTFail("ImageRenderer drew nothing for \(name)") }
        guard let canvas = CGContext(data: nil, width: drawn.width, height: drawn.height, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: VideoView.colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw RenderError.write("CGContext for \(name)") }
        canvas.setFillColor(NSColor(hex: Theme.Hex.background).cgColor)
        let bounds = CGRect(x: 0, y: 0, width: drawn.width, height: drawn.height)
        canvas.fill(bounds)
        canvas.draw(drawn, in: bounds)
        guard let image = canvas.makeImage() else { throw RenderError.write("image for \(name)") }
        let url = Gallery.directory.appendingPathComponent("offscreen-\(name).png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw RenderError.write(url.path)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw RenderError.write(url.path) }
    }

    @MainActor
    private func waitUntil(_ what: String, timeout: Double = 10, _ condition: () -> Bool) async throws {
        let deadline = CACurrentMediaTime() + timeout
        while !condition() {
            guard CACurrentMediaTime() < deadline else { throw RenderError.timedOut(what) }
            try await pump(0.02)
        }
    }
}

private enum Gallery {
    /// NITIDO_RENDER_DIR, or a folder in the temporary directory.
    static var directory: URL {
        if let dir = ProcessInfo.processInfo.environment["NITIDO_RENDER_DIR"] { return URL(fileURLWithPath: dir, isDirectory: true) }
        return FileManager.default.temporaryDirectory.appendingPathComponent("nitido-renders", isDirectory: true)
    }
}

private enum RenderError: Error {
    case write(String)
    case timedOut(String)
    case capture(String)
}

/// Runs the main thread's events for `seconds`: a test drives no `NSApp.run()`, and without it a window never hears that
/// it is on screen (its occlusion state), so Metal never draws the picture.
@MainActor
private func pump(_ seconds: Double) async throws {
    let end = CACurrentMediaTime() + seconds
    repeat {
        while let event = NSApp.nextEvent(matching: .any, until: nil, inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
        try await Task.sleep(for: .milliseconds(8))
    } while CACurrentMediaTime() < end
}

/// A real window on screen holding one screen, sized to it as `.windowResizability(.contentSize)` sizes the app's.
@MainActor
private final class Stage {
    let window: NSWindow
    private let host: NSHostingView<AnyView>

    init(_ view: some View, at origin: CGPoint) {
        host = NSHostingView(rootView: AnyView(view.environment(\.colorScheme, .dark)))
        window = KeyWindow(contentRect: CGRect(origin: origin, size: host.fittingSize), styleMask: [.titled, .closable, .miniaturizable],
                           backing: .buffered, defer: false)
        window.title = "Nítido"
        // The app's window chrome (`NitidoApp`): no title, a transparent title bar on the background.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = NSColor(hex: Theme.Hex.background)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.contentView = host
        // Above every other app's windows, so the picture is not covered and Metal draws it.
        window.level = .floating
        avoidPointer()
        window.orderFrontRegardless()
        window.makeKey()
    }

    /// Waits until the window is on screen (Metal draws only then), then `settle` seconds for entrances, the ring and
    /// the strip's figures, then captures the window without its shadow.
    func capture(_ name: String, settle: Double = 0.5) async throws {
        let deadline = CACurrentMediaTime() + 3
        while !window.occlusionState.contains(.visible), CACurrentMediaTime() < deadline { try await pump(0.05) }
        fit()
        try await pump(settle)
        fit()
        try await pump(0.12)
        try Self.screencapture(window.windowNumber, as: "window-\(name)")
    }

    /// The window with the sheet a confirmation dialog put on it (macOS 26 draws the sheet into the window).
    func captureSheet(_ name: String, settle: Double) async throws {
        try await pump(settle)
        guard window.attachedSheet != nil || !window.sheets.isEmpty else { throw RenderError.capture("no sheet on the window for \(name)") }
        try Self.screencapture(window.windowNumber, as: "window-\(name)")
    }

    func close() { window.orderOut(nil); window.close() }

    /// Sizes the window to its content, keeping its top left corner, in one move that never lands on the pointer.
    private func fit() {
        let current = window.frame
        var frame = window.frameRect(forContentRect: CGRect(origin: .zero, size: host.fittingSize))
        frame.origin = CGPoint(x: current.minX, y: current.maxY - frame.height)
        frame.origin.x = Self.clearOfPointer(frame)
        if frame != current { window.setFrame(frame, display: true) }
    }

    /// Where the window's left edge goes so the window is off the pointer: while a system picker is up (one another app
    /// left open, say), it tints the window the pointer is over blue, and keeps that tint until the pointer moves, so
    /// the window must never pass under it.
    /// A window grows to the right as its content does (AppKit keeps its origin), so the check covers the widest screen
    /// in the gallery, 760 pt, not only the width it has now.
    private static func clearOfPointer(_ frame: CGRect) -> CGFloat {
        let pointer = NSEvent.mouseLocation
        let reach = max(frame.width, 760)
        guard (frame.minX - 24...frame.minX + reach + 24).contains(pointer.x) else { return frame.minX }
        return pointer.x - 48 - reach >= 0 ? pointer.x - 48 - reach : pointer.x + 48
    }

    private func avoidPointer() { window.setFrameOrigin(CGPoint(x: Self.clearOfPointer(window.frame), y: window.frame.minY)) }

    private static func screencapture(_ windowNumber: Int, as name: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", "\(windowNumber)", Gallery.directory.appendingPathComponent("\(name).png").path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw RenderError.capture("screencapture exited \(process.terminationStatus) for \(name)") }
    }
}

/// Says it is the key window, so SwiftUI focuses the code field and draws its caret: a test process cannot take
/// activation from the app in front. It draws as one too: AppKit tints a switch and a slider, and colours the traffic
/// lights, only in a window with key appearance, which no window of an inactive app has, so the Codec loop switch drew
/// grey while it was on. `hasKeyAppearance` is the AppKit method that decides it; the SDK's headers leave it out, so
/// this answers its selector (a test's window only: the app's windows are a real active app's).
private final class KeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    @objc(hasKeyAppearance) func drawsAsKey() -> Bool { true }
}

/// Raises Esc's confirmation over a screen, as `RootView` does, with the app's own wording (`AppModel.stopWording`).
@MainActor @Observable
private final class DialogFlag {
    var shown = false
    var question = ""
    var action = ""
    var message = ""
}

private struct DialogHost<Content: View>: View {
    @Bindable var flag: DialogFlag
    @ViewBuilder let content: () -> Content
    var body: some View {
        content().confirmationDialog(flag.question, isPresented: $flag.shown) {
            Button(flag.action, role: .destructive) {}
        } message: {
            Text(flag.message)
        }
    }
}

/// Makes the share's sources and knows the current one.
@MainActor
private final class PictureSources {
    private(set) var current: PictureSource?
    private(set) var count = 0
    func make() -> any CaptureSource { let source = PictureSource(); current = source; count += 1; return source }
}

/// Stands in for the capture session: the picker never opens, and events and frames come on demand.
@MainActor
private final class PictureSource: CaptureSource {
    let frames: AsyncStream<CapturedFrame>
    let events: AsyncStream<CaptureEvent>
    private let frameOut: AsyncStream<CapturedFrame>.Continuation
    private let eventOut: AsyncStream<CaptureEvent>.Continuation
    init() {
        (frames, frameOut) = AsyncStream<CapturedFrame>.makeStream(bufferingPolicy: .bufferingNewest(2))
        (events, eventOut) = AsyncStream<CaptureEvent>.makeStream()
    }
    func presentPicker(excludingWindowIDs: [CGWindowID]) {}
    func stop() async {}
    func emit(_ event: CaptureEvent) { eventOut.yield(event) }
    func emit(frame: CapturedFrame) { frameOut.yield(frame) }
}

/// A desktop to share: a wallpaper, a light document at the top right (under the pairing panel, the hardest place for
/// glass to stay legible) and a dark editor at the bottom left (under the notices).
@MainActor
private enum Picture {
    static func desktop(width: Int, height: Int, caret: Bool) throws -> CVPixelBuffer {
        var made: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
        let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &made)
        guard status == kCVReturnSuccess, let buffer = made else { throw RenderError.write("CVPixelBufferCreate \(status)") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: VideoView.colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw RenderError.write("CGContext") }
        // Top-left origin, as a screen reads.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.current = previous }
        draw(CGSize(width: width, height: height), caret: caret)
        return buffer
    }

    private static func draw(_ size: CGSize, caret: Bool) {
        let w = size.width, h = size.height
        NSGradient(colors: [NSColor(srgbRed: 0.10, green: 0.20, blue: 0.42, alpha: 1), NSColor(srgbRed: 0.55, green: 0.32, blue: 0.62, alpha: 1),
                            NSColor(srgbRed: 0.95, green: 0.62, blue: 0.38, alpha: 1)])!
            .draw(in: CGRect(origin: .zero, size: size), angle: -35)

        let doc = CGRect(x: w * 0.30, y: h * 0.04, width: w * 0.67, height: h * 0.62)
        window(doc, title: "Launch plan", dark: false)
        let left = doc.minX + 56
        var y = doc.minY + 96
        text("Launch plan", at: CGPoint(x: left, y: y), size: 40, weight: .bold, color: .black)
        y += 70
        let lines = [
            "The first public build goes out on Monday. Before then the team checks every screen at",
            "1:1 on a Retina display, reads the latency figures on two Macs, and signs off the copy.",
            "Ink stays on top of the picture and fades four seconds after the last stroke.",
            "",
            "Open questions",
            "1. Does the code read at arm's length on a 14-inch display?",
            "2. Is the strip quiet enough when nothing is wrong?",
            "3. Which figures turn gold, and for how long?",
        ]
        for line in lines {
            let heading = line == "Open questions"
            text(line, at: CGPoint(x: left, y: y), size: heading ? 28 : 24, weight: heading ? .semibold : .regular,
                 color: NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1))
            y += heading ? 48 : 40
        }
        if caret { NSColor.systemBlue.setFill(); CGRect(x: left + 760, y: y - 36, width: 3, height: 30).fill() }

        let editor = CGRect(x: w * 0.03, y: h * 0.50, width: w * 0.52, height: h * 0.46)
        window(editor, title: "ShareView.swift", dark: true)
        let keyword = NSColor(srgbRed: 0.99, green: 0.37, blue: 0.53, alpha: 1), plain = NSColor(srgbRed: 0.84, green: 0.84, blue: 0.86, alpha: 1)
        let type = NSColor(srgbRed: 0.40, green: 0.80, blue: 0.95, alpha: 1), call = NSColor(srgbRed: 0.98, green: 0.78, blue: 0.40, alpha: 1)
        let code: [(String, NSColor)] = [
            ("struct PairingPanel: View {", keyword), ("    let name: String, code: String", plain), ("    var body: some View {", keyword),
            ("        GlassCard {", type), ("            Text(code)", type), ("                .font(.figures(26))", call),
            ("        }", plain), ("    }", plain), ("}", plain),
        ]
        var cy = editor.minY + 84
        for (line, color) in code {
            text(line, at: CGPoint(x: editor.minX + 40, y: cy), size: 22, weight: .regular, color: color, mono: true)
            cy += 36
        }
    }

    private static func window(_ frame: CGRect, title: String, dark: Bool) {
        let shape = NSBezierPath(roundedRect: frame, xRadius: 20, yRadius: 20)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45); shadow.shadowBlurRadius = 40; shadow.shadowOffset = NSSize(width: 0, height: -12)
        shadow.set()
        (dark ? NSColor(srgbRed: 0.12, green: 0.12, blue: 0.14, alpha: 1) : NSColor.white).setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        (dark ? NSColor(srgbRed: 0.17, green: 0.17, blue: 0.19, alpha: 1) : NSColor(srgbRed: 0.93, green: 0.93, blue: 0.94, alpha: 1)).setFill()
        CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 56).fill()
        NSGraphicsContext.restoreGraphicsState()
        for (i, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            color.setFill()
            NSBezierPath(ovalIn: CGRect(x: frame.minX + 24 + CGFloat(i) * 36, y: frame.minY + 18, width: 22, height: 22)).fill()
        }
        text(title, at: CGPoint(x: frame.midX - 70, y: frame.minY + 14), size: 22, weight: .semibold,
             color: dark ? NSColor(white: 0.85, alpha: 1) : NSColor(white: 0.25, alpha: 1))
    }

    private static func text(_ string: String, at point: CGPoint, size: CGFloat, weight: NSFont.Weight, color: NSColor, mono: Bool = false) {
        let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color]).draw(at: point)
    }
}


// MARK: - The motion reel (NITIDO_MOTION=1)

/// The choreography recorded (spec 11): every moment played through the real models in the real screens, captured with
/// `screencapture -V`, and cut into contact sheets of ten frames 50 ms apart from each moment's start. Skipped unless
/// NITIDO_RENDER=1 and NITIDO_MOTION=1:
///
///     NITIDO_RENDER=1 NITIDO_MOTION=1 NITIDO_MOTION_DIR=/some/dir swift test --filter RenderGallery/testMotionReel
///
/// Two runs of one scenario (`ReelDirector`). The window's growth belongs to SwiftUI's `Window` scene, which a hand-made
/// window cannot reproduce (it never animates its frame), and SwiftUI never puts a scene's window on screen for a process
/// that is not the active app (a plain process, an app bundle and LaunchServices alike, 2026-10-12), though it animates
/// that window's frame all the same. So:
/// - `frames`: a child process runs this bundle's `testMotionHost`, which runs `MotionReelApp`, the app's own `Window`
///   scene twice (one for each Mac), off screen, and logs every step of both windows' frames for each moment
///   (`frames/<moment>.csv`): the growth, its curve and its timing as the app has them.
/// - `visual`: the same moments in windows of this process, recorded. Each window's frame takes, at every step, the size
///   its root reports (`AnimatedArea` animates that size frame by frame, which is what the scene's window follows), from
///   the top left corner, the content laid out at its final size as in the app.
/// The system picker never opens, nothing waits on a person, and every recording covers only Nítido's windows on a plain
/// backdrop. Each carries a sync marker, a small white square in its top left corner for one frame where its moment
/// starts. The press (M2) is recorded in a window that takes the first click: this process is never the active app.
extension RenderGallery {
    @MainActor
    func testMotionReel() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["NITIDO_MOTION"] == "1", "set NITIDO_MOTION=1 to record the motion reel")
        try XCTSkipIf(env["NITIDO_MOTION_HOST"] == "1", "the host process runs testMotionHost alone")
        for dir in [MotionReel.clips, MotionReel.sheets, MotionReel.frames] {
            try? FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        FontLoader.registerBundledFonts()
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.finishLaunching()
        try await pump(0.3)

        // The app's own scene, off screen, in a child process: the window's frame at every step.
        let hostStatus = try await runFrameHost()

        var manifest = try await recordPress()
        let director = ReelDirector(mode: .visual)
        do {
            try await director.play()
        } catch {
            XCTFail("the reel stopped: \(error)")
        }
        director.tearDown()
        manifest += director.clips

        // A movie whose recording did not finish may hold whatever the screen showed once the reel was gone: it goes.
        let finished = Set(manifest.map { "\($0.name).mov" })
        for file in (try? FileManager.default.contentsOfDirectory(atPath: MotionReel.clips.path)) ?? [] where file.hasSuffix(".mov") && !finished.contains(file) {
            try? FileManager.default.removeItem(at: MotionReel.clips.appendingPathComponent(file))
        }
        for clip in manifest { try MotionReel.cut(clip) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: MotionReel.clips.appendingPathComponent("manifest.json"))
        XCTAssertEqual(hostStatus, 0, "the scene's run ended with \(hostStatus); see \(MotionReel.frames.appendingPathComponent("host.log").path)")
    }

    /// The child process's one test: the app's own scenes, which log their frames for every moment, then end the process.
    @MainActor
    func testMotionHost() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NITIDO_MOTION_HOST"] == "1", "run by testMotionReel")
        MotionReelApp.main()
    }

    /// Runs `testMotionHost` in a child process (this bundle, by the runner that runs this test) and waits for it.
    @MainActor
    private func runFrameHost() async throws -> Int32 {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["-XCTest", "NitidoUITests.RenderGallery/testMotionHost", Bundle(for: RenderGallery.self).bundlePath]
        var env = ProcessInfo.processInfo.environment
        env["NITIDO_MOTION_HOST"] = "1"
        child.environment = env
        let log = MotionReel.frames.appendingPathComponent("host.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        child.standardOutput = handle; child.standardError = handle
        try child.run()
        let deadline = Date().addingTimeInterval(320)
        while child.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(200)) }
        if child.isRunning { child.terminate(); return -1 }
        return child.terminationStatus
    }

    /// M2: a press on the gold and the quiet button and on a row of the list, held 300 ms each.
    @MainActor
    private func recordPress() async throws -> [ReelClip] {
        let content = VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 12) { GoldButton("Share") {}; QuietButton("View") {} }
            PressRowSample()
        }
        .padding(24)
        .frame(width: 600, height: 180, alignment: .topLeading)
        .background(Theme.Colors.background)
        let host = ReelFirstMouseView(rootView: AnyView(content.environment(\.colorScheme, .dark)))
        let rect = CGRect(x: 40, y: 200, width: 600, height: 180)
        let window = NSWindow(contentRect: CGRect(x: rect.minX, y: NSScreen.main!.frame.height - rect.maxY, width: rect.width, height: rect.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.level = .floating
        window.backgroundColor = NSColor(hex: Theme.Hex.background)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await pump(0.8)
        let marker = ReelMarker(rect: rect)
        defer { marker.close() }
        let clip = ReelClip(name: "press", rect: rect, markers: ["share", "view", "row"], sheets: 1,
                            crops: [ReelCrop(name: "buttons", x: 16, y: 16, width: 236, height: 48)])
        let recorder = try ReelRecorder(clip, seconds: 3.4)
        try await pump(0.9)
        for (index, point) in [CGPoint(x: 72, y: 40), CGPoint(x: 180, y: 40), CGPoint(x: 300, y: 104)].enumerated() {
            marker.flash()
            send(.leftMouseDown, at: point, to: window, host: host)
            try await pump(0.3)
            send(.leftMouseUp, at: point, to: window, host: host)
            try await pump(index == 2 ? 0.6 : 0.5)
        }
        try await recorder.finish()
        return [clip]
    }

    @MainActor
    private func send(_ type: NSEvent.EventType, at point: CGPoint, to window: NSWindow, host: NSView) {
        let location = host.convert(point, to: nil)
        guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                             pressure: type == .leftMouseUp ? 0 : 1) else { return }
        window.sendEvent(event)
    }
}

/// One row of the list of Macs, for the press (it is private to the View screen).
private struct PressRowSample: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
        Button {} label: {
            HStack(spacing: 12) {
                Image(systemName: "laptopcomputer").font(.system(size: 15)).foregroundStyle(Theme.Colors.secondaryText).frame(width: 22)
                Text("Mac Studio de Ana").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.Colors.text)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.Colors.secondaryText)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 48, maxHeight: 48)
            .background(shape.fill(Theme.Colors.surface))
            .overlay(shape.strokeBorder(Theme.Colors.hairline, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(PressFeedback(pressScale: Theme.Motion.pressScaleWide))
    }
}

/// Takes the first click like a window of the active app does: this process is never the active app.
private final class ReelFirstMouseView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Where the reel writes: NITIDO_MOTION_DIR, or a folder in the temporary directory; the clips and the sheets in it.
private enum MotionReel {
    static var directory: URL {
        if let dir = ProcessInfo.processInfo.environment["NITIDO_MOTION_DIR"] { return URL(fileURLWithPath: dir, isDirectory: true) }
        return FileManager.default.temporaryDirectory.appendingPathComponent("nitido-motion", isDirectory: true)
    }
    static var clips: URL { directory.appendingPathComponent("clips", isDirectory: true) }
    static var sheets: URL { directory.appendingPathComponent("sheets", isDirectory: true) }
    static var frames: URL { directory.appendingPathComponent("frames", isDirectory: true) }
    static let ffmpeg = "/opt/homebrew/bin/ffmpeg"
    static let ffprobe = "/opt/homebrew/bin/ffprobe"

    /// The clip's contact sheets: for each marker, `sheets` rows of ten frames 50 ms apart from the frame the marker
    /// shows in, the whole recording and each crop.
    static func cut(_ clip: ReelClip) throws {
        let movie = clips.appendingPathComponent("\(clip.name).mov")
        guard FileManager.default.fileExists(atPath: movie.path) else { throw ReelError.missing(movie.path) }
        let markers = try markerTimes(movie)
        guard !markers.isEmpty else { throw ReelError.noMarker(clip.name) }
        // The marker is a window of its own, which the window server shows a frame or three after the content's first
        // change: each sheet starts on the frame before the content first changes near its marker.
        let starts = try markers.map { try contentStart(movie, near: $0) }
        // screencapture writes a frame only when the screen changes, so a recording ends at its last change: the last
        // frame is held, and every sheet has its ten frames.
        let hold = "tpad=stop_mode=clone:stop_duration=4"
        for (index, start) in starts.enumerated() {
            let label = index < clip.markers.count ? clip.markers[index] : "m\(index)"
            for row in 0..<clip.sheets {
                let at = start + Double(row) * 0.5
                let width = min(Int(clip.rect.width * 2), 620)
                // Every frame of a 60 fps grid (a still stretch held), from `at`, then one in three: 50 ms apart.
                let from = "\(hold),fps=60,trim=start=\(String(format: "%.4f", at)),setpts=PTS-STARTPTS,fps=20"
                try run(ffmpeg, ["-y", "-loglevel", "error", "-i", movie.path,
                                 "-vf", "\(from),scale=\(width):-2,tile=10x1", "-frames:v", "1",
                                 sheets.appendingPathComponent("\(clip.name)-\(label)-\(row).png").path])
                for crop in clip.crops {
                    let c = "crop=\(Int(crop.width * 2)):\(Int(crop.height * 2)):\(Int(crop.x * 2)):\(Int(crop.y * 2))"
                    try run(ffmpeg, ["-y", "-loglevel", "error", "-i", movie.path,
                                     "-vf", "\(from),\(c),tile=10x1", "-frames:v", "1",
                                     sheets.appendingPathComponent("\(clip.name)-\(label)-\(crop.name)-\(row).png").path])
                }
            }
        }
        let times = starts.map { String(format: "%.3f", $0) }.joined(separator: " ")
        try "\(times)\n".write(to: sheets.appendingPathComponent("\(clip.name)-markers.txt"), atomically: true, encoding: .utf8)
    }

    /// The frame before the recorded content first changes near `marker` (from 250 ms before it to 350 ms after), at 60
    /// frames a second; the marker's own corner is left out. The marker's time if nothing changes.
    static func contentStart(_ movie: URL, near marker: Double) throws -> Double {
        let from = max(0, marker - 0.25)
        let width = 160, height = 100
        let raw = try runCapturing(ffmpeg, ["-loglevel", "error", "-i", movie.path, "-ss", String(format: "%.3f", from), "-t", "0.6",
                                            "-vf", "tpad=stop_mode=clone:stop_duration=1,fps=60,crop=iw:ih-48:0:48,scale=\(width):\(height),format=gray",
                                            "-f", "rawvideo", "-pix_fmt", "gray", "-"])
        let size = width * height
        let frames = raw.count / size
        guard frames > 1 else { return marker }
        let bytes = [UInt8](raw)
        for index in 1..<frames {
            var sum = 0
            for p in 0..<size { sum += abs(Int(bytes[index * size + p]) - Int(bytes[(index - 1) * size + p])) }
            if Double(sum) / Double(size) > 0.05 { return from + Double(index - 1) / 60 }
        }
        return marker
    }

    /// When the sync marker shows, in seconds into the movie at 60 frames a second: each rising edge.
    static func markerTimes(_ movie: URL) throws -> [Double] {
        let raw = try runCapturing(ffmpeg, ["-loglevel", "error", "-i", movie.path, "-vf", "fps=60,crop=8:8:6:6",
                                            "-f", "rawvideo", "-pix_fmt", "gray", "-"])
        var times: [Double] = []
        var on = false
        let frame = 64
        var index = 0
        while (index + 1) * frame <= raw.count {
            let slice = raw[(index * frame)..<((index + 1) * frame)]
            let mean = slice.reduce(0) { $0 + Int($1) } / frame
            if mean > 180, !on { times.append(Double(index) / 60) }
            on = mean > 180
            index += 1
        }
        return times
    }

    static func run(_ tool: String, _ arguments: [String]) throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = arguments
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw ReelError.tool("\(tool) \(arguments.joined(separator: " "))") }
    }

    static func runCapturing(_ tool: String, _ arguments: [String]) throws -> Data {
        let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = arguments
        let pipe = Pipe(); p.standardOutput = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return data
    }
}

private enum ReelError: Error {
    case missing(String)
    case noMarker(String)
    case tool(String)
    /// Something other than Nítido came into a take (`ReelDirector.intruder`): its recording is deleted.
    case intruded(String)
}

/// A recorded moment: its movie's name, the screen rect it recorded (top left origin, points), its markers in order,
/// how many sheets of half a second follow each, and the close-ups (in points within the rect).
private struct ReelClip: Codable {
    var name: String
    var rect: CGRect
    var markers: [String]
    var sheets: Int
    var crops: [ReelCrop] = []
}

private struct ReelCrop: Codable {
    var name: String
    var x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat
}

/// `screencapture -V` of a screen rect, started at once; `finish` waits for it. The rect must lie under the reel's
/// backdrop, so it holds nothing but Nítido's windows; and screencapture runs under a small guard that ends it the moment
/// the process that started it is gone, so a reel killed halfway never goes on recording whatever the screen shows next
/// (`testMotionReel` also deletes any movie whose recording did not finish).
@MainActor
private final class ReelRecorder {
    private let process = Process()
    private let movie: URL
    /// A file whose presence ends the recording at once and deletes it (`abandon`).
    private let stop: URL
    init(_ clip: ReelClip, seconds: Double) throws {
        let r = clip.rect
        movie = MotionReel.clips.appendingPathComponent("\(clip.name).mov")
        stop = MotionReel.clips.appendingPathComponent(".\(clip.name).stop")
        // screencapture does not write over a movie that is there.
        try? FileManager.default.removeItem(at: movie)
        try? FileManager.default.removeItem(at: stop)
        let capture = "/usr/sbin/screencapture -x -V \(String(format: "%.1f", seconds)) -R \(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height)) '\(movie.path)'"
        let owner = ProcessInfo.processInfo.processIdentifier
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "\(capture) & c=$!; while kill -0 \(owner) 2>/dev/null && kill -0 $c 2>/dev/null && [ ! -e '\(stop.path)' ]; do sleep 0.05; done; "
                             + "if kill -0 $c 2>/dev/null; then kill -9 $c; rm -f '\(movie.path)' '\(stop.path)'; exit 9; fi; wait $c"]
        try process.run()
    }
    /// Ends the recording within 50 ms and deletes it, without waiting: a take that failed, or that saw something other
    /// than Nítido, keeps nothing it recorded.
    func abandon() {
        FileManager.default.createFile(atPath: stop.path, contents: nil)
        Task { @MainActor [process, movie, stop] in
            let deadline = CACurrentMediaTime() + 3
            while process.isRunning, CACurrentMediaTime() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
            try? FileManager.default.removeItem(at: movie)
            try? FileManager.default.removeItem(at: stop)
        }
    }
    func finish() async throws {
        while process.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        guard process.terminationStatus == 0 else { throw ReelError.tool("screencapture exited \(process.terminationStatus)") }
    }
    /// Whether the recording has ended (it throws if it ended badly).
    func poll() throws -> Bool {
        guard !process.isRunning else { return false }
        guard process.terminationStatus == 0 else { throw ReelError.tool("screencapture exited \(process.terminationStatus)") }
        return true
    }
}

/// The sync marker: a white square of 6 pt in the top left corner of a recorded rect, shown for 50 ms where a moment
/// starts, in a window of its own above everything.
@MainActor
private final class ReelMarker {
    let rect: CGRect
    private let window: NSWindow
    init(rect: CGRect) {
        self.rect = rect
        let size: CGFloat = 8
        let screen = NSScreen.main!.frame.height
        window = NSWindow(contentRect: CGRect(x: rect.minX + 2, y: screen - rect.minY - 2 - size, width: size, height: size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = .white
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.alphaValue = 0
        window.orderFrontRegardless()
    }
    func flash() {
        window.alphaValue = 1
        Task { @MainActor [window] in
            try? await Task.sleep(for: .milliseconds(60))
            window.alphaValue = 0
        }
    }
    func close() { window.orderOut(nil) }
}

/// Reduce Motion for the reel's windows, switched for the variants; the figures without their roll, for the README's
/// GIF; and, for a still, no animation at all.
@MainActor @Observable
private final class ReelPolicy {
    var reduceMotion = false
    /// False for the README's take (`MotionPolicy.rollsFigures`): at 15 fps its GIF caught the strip's figures and the
    /// loop's quality halfway through their roll, two glyphs in one place, and "raw" and "HEVC" over each other.
    var rollsFigures = true
    /// Every change at once (the views' own `.animation` modifiers held off), so a still never catches a figure of the
    /// strip halfway through its roll, two digits over each other: the README's codec loop still did.
    var still = false
}

/// The app's root as the app shows it (`NitidoApp`): the window chrome, and Reduce Motion as the reel says.
private struct ReelRoot: View {
    let app: AppModel
    let policy: ReelPolicy
    var body: some View {
        let still = policy.still
        RootView(app: app)
            .environment(\.motionPolicy, MotionPolicy(reduceMotion: policy.reduceMotion, rollsFigures: policy.rollsFigures))
            .background(Theme.Colors.background)
            .environment(\.colorScheme, .dark)
            .transaction { if still { $0.disablesAnimations = true } }
    }
}

/// The child's app: the app's own `Window` scene twice, one for each Mac.
private struct MotionReelApp: App {
    init() {
        FontLoader.registerBundledFonts()
        let director = ReelDirector(mode: .frames)
        ReelDirector.hosted = director
        Task { @MainActor in await director.runHosted() }
    }

    var body: some Scene {
        // A test tool's process may not show windows (its activation policy is "prohibited"); as an accessory its scenes
        // open, off screen, and animate their frames.
        let _ = NSApp?.setActivationPolicy(.accessory)
        Window("Nítido", id: "share") { ReelSceneRoot(id: "share") }
            .windowResizability(.contentSize)
        Window("Nítido Viewer", id: "view") { ReelSceneRoot(id: "view") }
            .windowResizability(.contentSize)
            .commands { ReelCommands() }
    }
}

private struct ReelSceneRoot: View {
    let id: String
    var body: some View {
        if let director = ReelDirector.hosted {
            ReelRoot(app: id == "share" ? director.shareApp : director.viewApp, policy: director.policy)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .toolbar(removing: .title)
                .containerBackground(Theme.Colors.background, for: .window)
        }
    }
}

/// Hands the scenes' `openWindow` to the director: in a test tool's process SwiftUI opens no window at launch.
private struct ReelCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        let open = openWindow
        let _ = { ReelDirector.hosted?.opener = { open(id: $0) } }()
        CommandGroup(after: .newItem) { Button("Open the reel's windows") { open(id: "share") } }
    }
}

/// One of the reel's windows. Visual: a window of this process whose frame follows the size its root reports at every
/// step, as the scene's window does (`AnimatedArea` animates that size frame by frame), the content pinned to the top
/// left corner. Frames: the scene's own window, off screen, whose every step is logged.
@MainActor
private final class ReelWindow {
    let window: NSWindow
    private let host: NSHostingView<AnyView>?
    private var content: CGSize = .zero
    private var observer: NSObjectProtocol?
    private(set) var log: [(t: CFTimeInterval, size: CGSize, origin: CGPoint)] = []
    var logging = false

    /// A window of this process holding `root`.
    init(visual root: some View, corner: CGPoint) {
        // It takes the first click, as a window of the active app does, for the README's reel (`testReadmeReel`), whose
        // presses, strokes and drags are events sent to it: this process is never the active app.
        // The root at the top left of the hosting view, as the window's top left corner stays put: for the frame between
        // the root's new size and the window's (`step`), a root shorter than the window is not centred in it, 14 px low.
        let host: NSHostingView<AnyView> = ReelFirstMouseView(rootView: AnyView(root.frame(maxWidth: .infinity, maxHeight: .infinity,
                                                                                           alignment: .topLeading)))
        // Its ideal size as an intrinsic size, nothing pinning the window to it: the reel sets the frame itself.
        host.sizingOptions = [.intrinsicContentSize]
        self.host = host
        let size = host.intrinsicContentSize
        content = size
        let window = KeyWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable],
                               backing: .buffered, defer: false)
        window.title = "Nítido"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = NSColor(hex: Theme.Hex.background)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        let pin = ReelPinView(frame: CGRect(origin: .zero, size: size))
        pin.addSubview(host)
        host.frame = CGRect(origin: .zero, size: size)
        window.contentView = pin
        window.level = .floating
        self.window = window
        place(at: corner)
        window.orderFrontRegardless()
    }

    /// The scene's own window.
    init(scene window: NSWindow) {
        self.window = window
        host = nil
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.logging else { return }
                self.log.append((CACurrentMediaTime(), self.window.contentLayoutRect.size, self.window.frame.origin))
            }
        }
    }

    func place(at corner: CGPoint) {
        window.setFrameTopLeftPoint(CGPoint(x: corner.x, y: NSScreen.main!.frame.height - corner.y))
    }

    /// The content's origin within a recorded rect (top left origin, points).
    func contentOrigin(in rect: CGRect) -> CGPoint {
        let frame = window.frame, layout = window.contentLayoutRect
        let top = NSScreen.main!.frame.height - frame.maxY + (frame.height - layout.maxY)
        return CGPoint(x: frame.minX - rect.minX, y: top - rect.minY)
    }

    func startLog() { log = [(CACurrentMediaTime(), window.contentLayoutRect.size, window.frame.origin)]; logging = true }

    /// One step of the visual window: the frame takes the size the root reports now, top left fixed.
    func step(now: CFTimeInterval) {
        guard let host else { return }
        // Asked again at every step, without forcing a layout pass (which would cut short the animations under way).
        host.invalidateIntrinsicContentSize()
        let target = host.intrinsicContentSize
        guard target.width > 0, target.height > 0, target != content else { return }
        host.frame = CGRect(origin: .zero, size: target)
        resize(to: target)
    }

    private func resize(to size: CGSize) {
        guard size != content || window.contentLayoutRect.size != size else { return }
        content = size
        let top = window.frame.maxY
        var frame = window.frameRect(forContentRect: CGRect(origin: .zero, size: size))
        frame.origin = CGPoint(x: window.frame.minX, y: top - frame.height)
        window.setFrame(frame, display: true)
    }

    func close() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        window.orderOut(nil)
    }

    /// A point of the content (top left origin, points) on screen (bottom left origin, points).
    func screenPoint(_ point: CGPoint) -> CGPoint {
        guard let host else { return .zero }
        return window.convertPoint(toScreen: host.convert(point, to: nil))
    }

    /// The view a press went to straight, and its drags and release after it (`send`).
    private var pressed: NSView?

    /// A mouse event at a point of the content (top left origin, points), delivered as the window server delivers it to
    /// the active app. This process never is, so the window would keep a first click from a view that does not take
    /// one (the ink's canvas): a press on such a view, and its drags and release, go to it straight.
    func send(_ type: NSEvent.EventType, at point: CGPoint) {
        guard let host, let content = window.contentView else { return }
        let location = host.convert(point, to: nil)
        guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
        else { return }
        switch type {
        case .leftMouseDown:
            if let hit = content.hitTest(location), !hit.acceptsFirstMouse(for: event) {
                pressed = hit
                hit.mouseDown(with: event)
            } else {
                pressed = nil
                window.sendEvent(event)
            }
        case .leftMouseDragged:
            if let pressed { pressed.mouseDragged(with: event) } else { window.sendEvent(event) }
        case .leftMouseUp:
            if let pressed { pressed.mouseUp(with: event) } else { window.sendEvent(event) }
            pressed = nil
        default:
            window.sendEvent(event)
        }
    }

    /// The frame (content points, top left origin) of the content's first accessibility element with `role` whose label
    /// is `label` (any label when nil): where a person would point at a control, read as VoiceOver reads it.
    func elementFrame(role: NSAccessibility.Role, label: String? = nil) -> CGRect? {
        guard let host else { return nil }
        func find(_ element: Any, depth: Int) -> CGRect? {
            guard depth < 64, let node = element as? NSAccessibilityProtocol else { return nil }
            if node.accessibilityRole() == role, label == nil || node.accessibilityLabel() == label {
                return host.convert(window.convertFromScreen(node.accessibilityFrame()), from: nil)
            }
            for child in node.accessibilityChildren() ?? [] {
                if let frame = find(child, depth: depth + 1) { return frame }
            }
            return nil
        }
        return find(host, depth: 0)
    }

    /// The content's first AppKit control of class `T` and its frame (content points, top left origin). SwiftUI draws
    /// its switch and its slider with an NSSwitch and an NSSlider, and builds no accessibility tree in a process that no
    /// assistive app reads, so `elementFrame` finds neither here (the Codec loop's arrow landed beside the switch, on a
    /// guessed frame).
    func control<T: NSControl>(_ type: T.Type) -> (control: T, frame: CGRect)? {
        guard let host else { return nil }
        func find(_ view: NSView) -> T? {
            if let match = view as? T { return match }
            for subview in view.subviews { if let match = find(subview) { return match } }
            return nil
        }
        guard let found = find(host) else { return nil }
        return (found, found.convert(found.bounds, to: host))
    }
}

/// Keeps the content at the top left corner, at its own size, however large the window is.
private final class ReelPinView: NSView {
    override var isFlipped: Bool { true }
}

/// Plays the choreography's moments in order: recorded in the visual run, the scene's frames logged in the frames run.
@MainActor
private final class ReelDirector {
    enum Mode { case visual, frames }
    /// The child's director, which its scenes read.
    static var hosted: ReelDirector?

    let mode: Mode
    let sources = PictureSources()
    let policy = ReelPolicy()
    var opener: ((String) -> Void)?
    private(set) var clips: [ReelClip] = []
    private var pictures: [CVPixelBuffer] = []
    private var pictureSize = CGSize.zero
    private var feed: Task<Void, Never>?
    private var peers: [Peer] = []
    private var backdrop: NSWindow?
    /// The sharer's dropped frames and rates per moment (`record`).
    private var hotPath = "moment,dropped,capture_fps,display_fps\n"
    private var share: ReelWindow?
    private var view: ReelWindow?
    /// Checked as a take runs (`pause`), at most every 100 ms: it throws once the take can no longer be kept.
    private var watch: (() throws -> Void)?
    private var watchedAt: CFTimeInterval = 0

    init(mode: Mode) { self.mode = mode }

    lazy var shareApp: AppModel = {
        let sources = self.sources
        return AppModel(makeShare: { ShareModel(makeSource: { sources.make() }, screenRecordingGranted: { true }) },
                        makeView: { ViewModel(startingDiscovery: false) }, terminate: {}, revealWindow: {}, hideWindows: {})
    }()

    lazy var viewApp: AppModel = {
        AppModel(makeShare: { ShareModel(makeSource: { PictureSource() }, screenRecordingGranted: { true }) },
                 makeView: { [weak self] in
                     let v = ViewModel(startingDiscovery: false)
                     v.peers = self?.peers ?? []
                     return v
                 }, terminate: {}, revealWindow: {}, hideWindows: {})
    }()

    /// The share window's top left corner and the viewer's, on screen (top left origin, points), and what is recorded.
    private let shareCorner = CGPoint(x: 12, y: 44)
    private let viewCorner = CGPoint(x: 686, y: 44)
    private var backdropRect: CGRect { CGRect(x: 0, y: 30, width: NSScreen.main!.frame.width, height: 610) }
    private var shareRect: CGRect { CGRect(x: 2, y: 34, width: 836, height: 600) }
    private var bothRect: CGRect { CGRect(x: 0, y: 34, width: NSScreen.main!.frame.width, height: 560) }
    private var viewRect: CGRect { CGRect(x: viewCorner.x - 10, y: 34, width: 676, height: 560) }

    /// The child's run: whatever happens, the process ends and the frames written so far stay.
    func runHosted() async {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(280))
            print("motion reel: watchdog fired"); fflush(stdout); exit(1)
        }
        do {
            try await play()
            print("motion reel: frames done"); fflush(stdout)
            exit(0)
        } catch {
            print("motion reel failed: \(error)"); fflush(stdout)
            exit(1)
        }
    }

    func tearDown() {
        feed?.cancel()
        share?.close(); view?.close()
        backdrop?.orderOut(nil)
    }

    /// Waits `seconds`, the windows following their content meanwhile (visual), or the app's run loop turning (frames).
    private func pause(_ seconds: Double) async throws {
        guard mode == .visual else { try await Task.sleep(for: .seconds(seconds)); return }
        let end = CACurrentMediaTime() + seconds
        repeat {
            while let event = NSApp.nextEvent(matching: .any, until: nil, inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
            let now = CACurrentMediaTime()
            share?.step(now: now); view?.step(now: now)
            if let watch, now - watchedAt >= 0.1 { watchedAt = now; try watch() }
            try await Task.sleep(for: .milliseconds(4))
        } while CACurrentMediaTime() < end
    }

    private func waitUntil(_ what: String, timeout: Double = 10, _ condition: () -> Bool) async throws {
        let deadline = CACurrentMediaTime() + timeout
        while !condition() {
            guard CACurrentMediaTime() < deadline else { throw RenderError.timedOut(what) }
            try await pause(0.02)
        }
    }

    private func sceneWindow(_ title: String) async throws -> NSWindow {
        let deadline = CACurrentMediaTime() + 10
        while CACurrentMediaTime() < deadline {
            if let w = NSApp.windows.first(where: { $0.title == title }) { return w }
            try await pause(0.05)
        }
        throw RenderError.timedOut("the window \(title)")
    }

    /// The share's window, or the viewer's, made for this run.
    private func openWindow(_ which: String) async throws -> ReelWindow {
        let app = which == "share" ? shareApp : viewApp
        switch mode {
        case .visual:
            return ReelWindow(visual: ReelRoot(app: app, policy: policy), corner: which == "share" ? shareCorner : viewCorner)
        case .frames:
            opener?(which)
            return ReelWindow(scene: try await sceneWindow(which == "share" ? "Nítido" : "Nítido Viewer"))
        }
    }

    /// Records the moment `name` (visual: the screen rect under the backdrop, its markers where `body` flashes them;
    /// frames: both windows' frames from the first flash, `frames/<name>.csv`).
    private func record(_ name: String, rect: CGRect, seconds: Double, markers: [String], sheets: Int = 2, crops: [ReelCrop] = [],
                        _ body: @MainActor (ReelMark) async throws -> Void) async throws {
        switch mode {
        case .visual:
            let clip = ReelClip(name: name, rect: rect, markers: markers, sheets: sheets, crops: crops)
            // Only what lies under the backdrop is recorded: Nítido's windows on a plain ground, nothing else.
            guard let backdrop, backdrop.isVisible, backdropRect.contains(rect) else { throw ReelError.tool("the backdrop does not cover \(name)") }
            let marker = ReelMarker(rect: rect)
            defer { marker.close() }
            let recorder = try ReelRecorder(clip, seconds: seconds)
            try await pause(0.9)
            // The hot path's pass mark (spec 11): frames dropped by the sharer during the moment and the second after it,
            // and its capture and display rates once it is over.
            let droppedBefore = shareApp.share?.droppedFramesTotal
            try await body(ReelMark { marker.flash() })
            try await pause(0.05)
            while true {
                let done = try recorder.poll()
                if done { break }
                try await pause(0.05)
            }
            if let share = shareApp.share, let droppedBefore, share.state == .capturing {
                let s = share.snapshot
                hotPath += String(format: "%@,%d,%.0f,%.0f\n", name, share.droppedFramesTotal - droppedBefore, s.captureFPS, s.displayFPS)
                try? hotPath.write(to: MotionReel.clips.appendingPathComponent("hot-path.csv"), atomically: true, encoding: .utf8)
            }
            clips.append(clip)
        case .frames:
            var start: CFTimeInterval?
            share?.startLog(); view?.startLog()
            try await body(ReelMark { if start == nil { start = CACurrentMediaTime() } })
            try await pause(max(0.6, seconds - 1.6))
            share?.logging = false; view?.logging = false
            var csv = "t_ms,window,width,height,x,y\n"
            for (label, w) in [("share", share), ("view", view)] {
                for entry in w?.log ?? [] {
                    csv += String(format: "%.1f,%@,%.0f,%.0f,%.0f,%.0f\n", (entry.t - (start ?? entry.t)) * 1000, label, entry.size.width,
                                  entry.size.height, entry.origin.x, entry.origin.y)
                }
            }
            try csv.write(to: MotionReel.frames.appendingPathComponent("\(name).csv"), atomically: true, encoding: .utf8)
        }
        print("motion reel: \(name)"); fflush(stdout)
    }

    /// Pictures drawn ahead for the next pick (drawing them takes a while), by size.
    private var prepared: (size: CGSize, pictures: [CVPixelBuffer])?

    /// Draws the pictures of a pick of `width` by `height` pixels before its moment starts.
    private func prepare(width: Int, height: Int) throws {
        let size = CGSize(width: width, height: height)
        guard prepared?.size != size else { return }
        prepared = (size, try [Picture.desktop(width: width, height: height, caret: true), Picture.desktop(width: width, height: height, caret: false)])
    }

    /// A new pick of `width` by `height` pixels at 2x: the capture says so, and frames of that size follow at 60 fps.
    private func pick(width: Int, height: Int) throws {
        try prepare(width: width, height: height)
        pictures = prepared?.pictures ?? []
        pictureSize = CGSize(width: width, height: height)
        sources.current?.emit(.started(pixelWidth: width, pixelHeight: height, scale: 2))
        guard feed == nil else { return }
        feed = Task { @MainActor [weak self] in
            var index = 0
            while !Task.isCancelled {
                if let self, !self.pictures.isEmpty {
                    let size = self.pictureSize
                    self.sources.current?.emit(frame: CapturedFrame(pixelBuffer: self.pictures[index / 30 % 2],
                                                                    captureHostTimeNs: UInt64(CACurrentMediaTime() * 1e9),
                                                                    contentRect: CGRect(x: 0, y: 0, width: size.width / 2, height: size.height / 2),
                                                                    scale: 2))
                }
                index += 1
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    /// A pick whose first frame comes `delay` seconds after the capture starts, as on a Mac whose first render is slow:
    /// the capture says so at once, and the feed sends nothing until then.
    private func pick(width: Int, height: Int, firstFrameAfter delay: Double) async throws {
        try prepare(width: width, height: height)
        let ready = prepared?.pictures ?? []
        pictures = []
        try pick(width: width, height: height)
        pictures = []
        try await pause(delay)
        pictures = ready
    }

    /// A crop of the share window's content (points from its content's top left), within the recorded rect.
    private func crop(_ name: String, of window: ReelWindow?, in rect: CGRect, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> ReelCrop {
        let origin = window?.contentOrigin(in: rect) ?? .zero
        let cx = max(0, min(origin.x + x, rect.width - width)), cy = max(0, min(origin.y + y, rect.height - height))
        return ReelCrop(name: name, x: cx, y: cy, width: width, height: height)
    }

    /// A plain backdrop behind the reel's windows over `rect` (top left origin, points), so the recordings hold nothing
    /// but Nítido.
    func raiseBackdrop(_ rect: CGRect) {
        let ground = NSWindow(contentRect: CGRect(x: rect.minX, y: NSScreen.main!.frame.height - rect.maxY, width: rect.width, height: rect.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        ground.backgroundColor = NSColor(srgbRed: 0.105, green: 0.11, blue: 0.125, alpha: 1)
        ground.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        ground.isReleasedWhenClosed = false
        ground.ignoresMouseEvents = true
        ground.orderFrontRegardless()
        backdrop = ground
    }

    /// The moments, in order.
    func play() async throws {
        if mode == .visual { raiseBackdrop(backdropRect) }
        let shareWindow = try await openWindow("share")
        share = shareWindow
        try await pause(1.5)

        // M1: the launch. Welcome is built anew for a launch while its window is away, and the window comes back.
        shareWindow.window.orderOut(nil)
        Instantly.run { shareApp.screen = .share }
        try await pause(0.2)
        shareApp.launchPlayed = false
        Instantly.run { shareApp.screen = .welcome }
        try await pause(0.3)
        try await record("welcome-launch", rect: shareRect, seconds: 3.0, markers: ["launch"], sheets: 3,
                         crops: [crop("card", of: shareWindow, in: shareRect, x: 34, y: 64, width: 532, height: 272)]) { mark in
            mark.flash()
            shareWindow.window.orderFrontRegardless()
        }

        // M3 and M6: Share, the picker's card; then a pick: the window grows to the picture and its entrance plays.
        try prepare(width: 1600, height: 1000)
        try await record("share-picture", rect: shareRect, seconds: 3.6, markers: ["share", "pick"], sheets: 2,
                         crops: [crop("panel", of: shareWindow, in: shareRect, x: 540, y: 0, width: 260, height: 150),
                                 crop("strip", of: shareWindow, in: shareRect, x: 0, y: 480, width: 800, height: 80)]) { mark in
            mark.flash()
            shareApp.startShare()
            try await pause(1.0)
            mark.flash()
            try pick(width: 1600, height: 1000)
            try await pause(1.4)
        }
        let share = try XCTUnwrap(shareApp.share)
        try await waitUntil("the sharer listens") { share.listeningPort != nil }

        // M8: a new code types itself in, after what three wrong codes do: a new code, and a listener keyed with it.
        try await record("code-reveal", rect: shareRect, seconds: 2.0, markers: ["rotate"], sheets: 2,
                         crops: [crop("code", of: shareWindow, in: shareRect, x: 600, y: 10, width: 200, height: 110)]) { mark in
            mark.flash()
            share.rotateCode()
            try await pause(0.8)
        }
        try await waitUntil("the sharer listens with the new code") { share.listeningPort != nil }

        // A later resize of the shared window: the window follows it.
        try prepare(width: 1300, height: 860)
        try await record("share-resize", rect: shareRect, seconds: 2.0, markers: ["resize"], sheets: 2) { mark in
            mark.flash()
            try pick(width: 1300, height: 860)
            try await pause(0.8)
        }

        // The viewer's window, at the right.
        let sharer = Peer(id: "loopback", name: share.advertisedName ?? share.name, keyName: share.name,
                          endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: share.listeningPort!)!))
        peers = [sharer, Peer(id: "b", name: "Mac Studio de Ana", keyName: "Mac Studio de Ana", endpoint: .hostPort(host: "127.0.0.1", port: 9)),
                 Peer(id: "c", name: "MacBook Air de Luis", keyName: "MacBook Air de Luis", endpoint: .hostPort(host: "127.0.0.1", port: 9))]
        viewApp.launchPlayed = true
        let viewWindow = try await openWindow("view")
        view = viewWindow
        try await pause(1.2)

        // M4: View; the list staggers in.
        try await record("view-list", rect: viewRect, seconds: 2.2, markers: ["view"], sheets: 2) { mark in
            mark.flash()
            viewApp.startView()
            try await pause(0.9)
        }
        let viewer = try XCTUnwrap(viewApp.view)
        // A Mac that appears alone rises at once; one that goes fades and the rows close up.
        try await record("view-arrival", rect: viewRect, seconds: 2.4, markers: ["arrives", "goes"], sheets: 1) { mark in
            mark.flash()
            viewer.peers.append(Peer(id: "d", name: "Mac mini del estudio", keyName: "Mac mini del estudio", endpoint: .hostPort(host: "127.0.0.1", port: 9)))
            try await pause(0.7)
            mark.flash()
            viewer.peers.removeAll { $0.id == "b" }
            try await pause(0.6)
        }

        // M5: a Mac picked, the code; a wrong code shakes; Back returns to the list (M19).
        try await record("view-code", rect: viewRect, seconds: 2.0, markers: ["pick"], sheets: 2) { mark in
            mark.flash()
            viewer.select(sharer)
            try await pause(0.8)
        }
        try await record("view-wrong-code", rect: viewRect, seconds: 2.0, markers: ["connect"], sheets: 2) { mark in
            viewer.code = share.code == "0000" ? "1111" : "0000"
            mark.flash()
            viewer.connect()
            try await waitUntil("the sharer turns the code away") { viewer.wrongCodeCount == 1 }
            try await pause(0.5)
        }
        try await record("view-back", rect: viewRect, seconds: 1.8, markers: ["back"], sheets: 1) { mark in
            mark.flash()
            viewer.disconnect()
            try await pause(0.6)
        }
        viewer.select(sharer)
        try await pause(0.6)

        // M7 and M9: the viewer connects; its window grows to the stream while the sharer's panel takes the viewer in.
        try await record("viewer-connecting", rect: bothRect, seconds: 3.0, markers: ["connect"], sheets: 3,
                         crops: [crop("sharer-panel", of: shareWindow, in: bothRect, x: 400, y: 0, width: 250, height: 190),
                                 crop("viewer-chip", of: viewWindow, in: bothRect, x: 420, y: 0, width: 230, height: 80)]) { mark in
            viewer.code = share.code
            mark.flash()
            viewer.connect()
            try await waitUntil("the viewer is connected") { viewer.state == .connected && share.viewerName != nil }
            try await pause(1.2)
        }

        // M15: the viewer draws, then takes the stroke back with ⌘Z: at once on the viewer, rewinding on the sharer.
        let theirs = viewer.ink.beginLocal(StrokePoint(x: 0.3, y: 0.55, pressure: 1, tMs: 0))
        viewer.ink.appendLocal(theirs, (1...40).map { i in
            let t = Double(i) / 40
            return StrokePoint(x: Float(0.3 + 0.3 * t), y: Float(0.55 + 0.08 * sin(t * .pi * 3)), pressure: 1, tMs: UInt32(i * 12))
        })
        viewer.ink.endLocal(theirs)
        try await pause(0.5)
        try await record("ink-undo", rect: bothRect, seconds: 1.8, markers: ["undo"], sheets: 1,
                         crops: [crop("sharer-ink", of: shareWindow, in: bothRect, x: 150, y: 150, width: 300, height: 140),
                                 crop("viewer-ink", of: viewWindow, in: bothRect, x: 150, y: 150, width: 300, height: 140)]) { mark in
            mark.flash()
            viewer.ink.undoLocal()
            try await pause(0.5)
        }

        // M12: the codec loop switched on by the pointer (what the switch's binding does, `LoopbackPanel.pointerToggle`),
        // off, then ⌘L, at once.
        let loopPanel = crop("panel", of: shareWindow, in: shareRect, x: 0, y: 0, width: 260, height: 190)
        try await record("codec-loop-on", rect: shareRect, seconds: 2.0, markers: ["on"], sheets: 2, crops: [loopPanel]) { mark in
            mark.flash()
            share.loopToggledAt = CACurrentMediaTime()
            withAnimation(Theme.Motion.move.animation) { share.loopback = true }
            try await pause(0.9)
        }
        try await record("codec-loop-off", rect: shareRect, seconds: 1.6, markers: ["off"], sheets: 1, crops: [loopPanel]) { mark in
            mark.flash()
            share.loopToggledAt = CACurrentMediaTime()
            withAnimation(LoopbackPanel.Unfold.fold.animation) { share.loopback = false }
            try await pause(0.5)
        }
        try await record("codec-loop-cmd-l", rect: shareRect, seconds: 1.6, markers: ["on", "off"], sheets: 1, crops: [loopPanel]) { mark in
            mark.flash()
            shareApp.toggleLoopback()
            try await pause(0.5)
            mark.flash()
            shareApp.toggleLoopback()
            try await pause(0.3)
        }
        // ⌘H, twice: the strip and the window's height at once.
        try await record("strip-cmd-h", rect: shareRect, seconds: 1.6, markers: ["hide", "show"], sheets: 1) { mark in
            mark.flash()
            shareApp.toggleTelemetry()
            try await pause(0.5)
            mark.flash()
            shareApp.toggleTelemetry()
            try await pause(0.3)
        }

        // M16: the capture stopped from the menu bar: Retry over the dimmed picture; the viewer is told.
        try await record("failure-card", rect: bothRect, seconds: 2.2, markers: ["failed"], sheets: 2) { mark in
            mark.flash()
            sources.current?.emit(.failed(CaptureFailure(reason: .stoppedFromMenuBar, detail: "stopped")))
            try await pause(1.0)
        }
        // Retry: the card gives way to the picker's card, then a pick brings the picture back.
        let sessions = sources.count
        try prepare(width: 1300, height: 860)
        try await record("retry", rect: shareRect, seconds: 2.8, markers: ["retry", "pick"], sheets: 1) { mark in
            mark.flash()
            share.retry()
            try await waitUntil("Retry opens a new session") { self.sources.count > sessions }
            try await pause(0.8)
            mark.flash()
            try pick(width: 1300, height: 860)
            try await pause(1.0)
        }
        try await waitUntil("the sharer listens again") { share.state == .capturing && share.listeningPort != nil }
        let again = Peer(id: "loopback", name: share.name, keyName: share.name,
                         endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: share.listeningPort!)!))
        viewer.disconnect()
        viewer.peers = [again]
        viewer.select(again)
        viewer.code = share.code
        viewer.connect()
        try await waitUntil("the viewer is connected again") { viewer.state == .connected && share.viewerName != nil }
        try await pause(1.5)

        // M10: the link drops without bye: the viewer dims its last frame and breathes a gold dot; the sharer's panel
        // says the viewer is reconnecting.
        try await record("reconnecting", rect: bothRect, seconds: 3.6, markers: ["drop"], sheets: 2,
                         crops: [crop("sharer-panel", of: shareWindow, in: bothRect, x: 400, y: 0, width: 250, height: 200),
                                 crop("viewer-pill", of: viewWindow, in: bothRect, x: 160, y: 150, width: 330, height: 130)]) { mark in
            mark.flash()
            share.advertiser?.stop()
            share.link?.abort()
            try await waitUntil("the viewer reconnects") { if case .reconnecting = viewer.state { return true }; return false }
            try await pause(2.0)
        }

        // M18: Disconnect and Stop, clicked in the question: each window closes in around Welcome's card.
        try await record("disconnect", rect: bothRect, seconds: 2.6, markers: ["disconnect", "stop"], sheets: 1) { mark in
            mark.flash()
            viewApp.confirmedStop()
            try await pause(0.7)
            mark.flash()
            shareApp.confirmedStop()
            try await pause(0.8)
        }

        // M17: Esc on the list: Welcome at once.
        viewApp.startView()
        try await pause(1.0)
        try await record("esc-from-list", rect: viewRect, seconds: 1.4, markers: ["esc"], sheets: 1) { mark in
            mark.flash()
            viewApp.escape()
            try await pause(0.4)
        }

        // M6 with a late first frame (a slow first render, a cold Mac): the window grows and the panels come as the
        // capture starts, and the cover over the picture stays opaque until its first frame is on screen, 300 ms later,
        // then fades from it.
        let lateFrom = sources.count
        try prepare(width: 1600, height: 1000)
        // A capture sends nothing before its pick: the feed stays quiet until the pick says otherwise.
        pictures = []
        try await record("share-first-frame-late", rect: shareRect, seconds: 3.4, markers: ["share", "pick"], sheets: 2,
                         crops: [crop("picture", of: shareWindow, in: shareRect, x: 120, y: 60, width: 400, height: 240)]) { mark in
            mark.flash()
            shareApp.startShare()
            try await waitUntil("a new session") { self.sources.count > lateFrom }
            try await pause(0.9)
            mark.flash()
            try await pick(width: 1600, height: 1000, firstFrameAfter: 0.3)
            try await pause(1.0)
        }
        await shareApp.stop()
        try await pause(0.6)

        // Reduce Motion: the share's picture and the launch again, fades only, the window at once.
        policy.reduceMotion = true
        try prepare(width: 1600, height: 1000)
        try await pause(0.3)
        pictures = []
        let reducedFrom = sources.count
        try await record("share-picture-reduced", rect: shareRect, seconds: 3.4, markers: ["share", "pick"], sheets: 2) { mark in
            mark.flash()
            shareApp.startShare()
            try await waitUntil("a new session") { self.sources.count > reducedFrom }
            try await pause(0.9)
            mark.flash()
            try pick(width: 1600, height: 1000)
            try await pause(1.2)
        }
        await shareApp.stop()
        try await pause(0.6)
        shareWindow.window.orderOut(nil)
        Instantly.run { shareApp.screen = .share }
        try await pause(0.2)
        shareApp.launchPlayed = false
        Instantly.run { shareApp.screen = .welcome }
        try await pause(0.3)
        try await record("welcome-launch-reduced", rect: shareRect, seconds: 2.4, markers: ["launch"], sheets: 2) { mark in
            mark.flash()
            shareWindow.window.orderFrontRegardless()
        }
        feed?.cancel(); feed = nil
    }
}

/// What a moment's body calls where the moment starts.
@MainActor
private struct ReelMark {
    let flash: @MainActor () -> Void
}

// MARK: - The README's reel (NITIDO_README=1)

/// The README's GIF (`docs/screenshots/loop.gif`): one take of the share window through its moments, played by the real
/// models in the real screens. The launch; a press on Share; the picture's entrance with the code; a viewer pairing over
/// the loopback link, the ring; a gold stroke drawn here and a cream one from the viewer; the codec loop switched on, its
/// divider dragged; both strokes fading; the quality lowered; the loop off; Stop, back to Welcome. The press, the stroke
/// and the drag are mouse events sent to the window, and a stand-in arrow is drawn where they land (the recording leaves
/// the real pointer out); the switch and the slider take the values their bindings would. The system picker never
/// opens, nothing waits on a person, and the recording covers only Nítido's window on a plain backdrop
/// (`ReadmeStream`). The strip's figures and the loop's quality change at once, without their roll
/// (`ReelPolicy.rollsFigures`). Skipped unless NITIDO_RENDER=1 and NITIDO_README=1:
///
///     NITIDO_RENDER=1 NITIDO_README=1 NITIDO_MOTION_DIR=/some/dir swift test --filter RenderGallery/testReadmeReel
///
/// It writes `clips/readme.mkv`, `clips/loop.gif` (19.6 s from Welcome to Welcome, the window and its margin, 1200 px
/// wide, or 1000 if that passes 6 MB, 15 fps) and `clips/codec-loop.png` (the codec loop on its own, captured from the
/// window after the take: the README's `02-share-loopback.png`).
extension RenderGallery {
    @MainActor
    func testReadmeReel() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NITIDO_README"] == "1", "set NITIDO_README=1 to record the README's reel")
        try? FileManager.default.removeItem(at: MotionReel.clips)
        try FileManager.default.createDirectory(at: MotionReel.clips, withIntermediateDirectories: true)
        FontLoader.registerBundledFonts()
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.finishLaunching()
        try await pump(0.3)
        let director = ReelDirector(mode: .visual)
        let take: ReadmeTake
        do {
            take = try await director.playReadme()
        } catch {
            director.tearDown()
            throw error
        }
        director.tearDown()
        let gif = try ReadmeTake.gif(take)
        print("README reel: \(MotionReel.clips.appendingPathComponent("loop.gif").path), \(gif.width) px wide, \(gif.bytes) bytes")
        XCTAssertLessThan(gif.bytes, ReadmeTake.limit, "the README's GIF should stay under 6 MB")
    }
}

/// What the README's take recorded: the movie, the screen rect it covers (top left origin, points) and how far into the
/// movie the window was put on screen (seconds).
private struct ReadmeTake {
    let movie: URL
    let rect: CGRect
    let launch: Double
    /// Where the GIF opens on the launch's clock: the card, the wordmark and the buttons have arrived (the last at
    /// 400 ms) and the glint is still to come (from 440 ms). So its first frame is Welcome, as its last is: the loop
    /// runs Welcome into Welcome with the glint, and a GIF that does not autoplay shows Welcome, not the empty window
    /// the launch starts from.
    static let opening: Double = 0.45
    static let seconds: Double = 19.6
    /// Stop, on the launch's clock: the recording must reach it, or the GIF would end on a frozen frame.
    static let stop: Double = 17.3
    /// Wide enough for the text to stay sharp on a Retina screen (the take is recorded at 2x, 1600 px), narrower if the
    /// GIF would pass `limit`.
    static let widths = [1200, 1000]
    static let limit = 6_000_000
    static let fps = 15

    /// The GIF: `opening` after the frame before the window's first change, `seconds` long, one palette made from the
    /// whole take, ordered dithering at a low scale (it stays put from frame to frame, so a still stretch costs nothing,
    /// and the low scale keeps gradients from banding) and only the changed rectangle written per frame. The first width
    /// in `widths` that stays under `limit`, or the last.
    static func gif(_ take: ReadmeTake) throws -> (width: Int, bytes: Int) {
        let launch = try MotionReel.contentStart(take.movie, near: take.launch)
        let start = launch + opening
        let probe = try MotionReel.runCapturing(MotionReel.ffprobe, ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", take.movie.path])
        let duration = Double(String(decoding: probe, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        guard duration >= launch + stop else {
            throw ReelError.tool(String(format: "the recording ends %.1f s into the take, before its Stop at %.1f s", duration - launch, stop))
        }
        let height = Int(take.rect.height * 2) / 2 * 2
        let gif = MotionReel.clips.appendingPathComponent("loop.gif")
        var result = (width: 0, bytes: 0)
        for width in widths {
            let chain = "fps=60,trim=start=\(String(format: "%.4f", start)):duration=\(seconds),"
                + "setpts=PTS-STARTPTS,crop=\(Int(take.rect.width * 2)):\(height):0:0,fps=\(fps),scale=\(width):-2:flags=lanczos,"
                + "split[a][b];[a]palettegen=max_colors=256:stats_mode=full[p];[b][p]paletteuse=dither=bayer:bayer_scale=2:diff_mode=rectangle"
            try MotionReel.run(MotionReel.ffmpeg, ["-y", "-loglevel", "error", "-i", take.movie.path, "-filter_complex", chain, "-loop", "0", gif.path])
            result = (width, (try FileManager.default.attributesOfItem(atPath: gif.path)[.size] as? Int) ?? 0)
            if result.bytes < limit { break }
        }
        return result
    }
}

/// A stand-in for the pointer, which the README's recording leaves out (`ReadmeStream`): the system's arrow with its tip
/// where the reel's events land, in a window of its own above the reel's windows, taking no click.
@MainActor
private final class ReelPointer {
    private let window: NSWindow
    private let hotSpot: CGPoint
    init() {
        let cursor = NSCursor.arrow
        hotSpot = cursor.hotSpot
        let size = cursor.image.size
        window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        window.isReleasedWhenClosed = false
        let image = NSImageView(frame: CGRect(origin: .zero, size: size))
        image.image = cursor.image
        image.imageScaling = .scaleNone
        window.contentView = image
        window.alphaValue = 0
        window.orderFrontRegardless()
    }
    /// The arrow's tip at `point` (screen, bottom left origin, points).
    func move(to point: CGPoint) {
        window.setFrameOrigin(CGPoint(x: point.x - hotSpot.x, y: point.y + hotSpot.y - window.frame.height))
    }
    /// Fades the arrow in or out over 120 ms.
    func show(_ shown: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            window.animator().alphaValue = shown ? 1 : 0
        }
    }
    func close() { window.orderOut(nil) }
}

/// The README's take, recorded by ScreenCaptureKit from this process: a rect of the main screen, under the reel's
/// backdrop, at 2x and `fps` frames a second, the real pointer left out. Each frame goes to ffmpeg as it comes and is
/// written lossless on the CPU, and a stretch the screen did not change as its last frame again, so the movie runs at
/// `fps` from its first frame. Not screencapture -V, which the motion reel uses: its 60 fps recording of the take's rect
/// made the codec loop drop up to 6 frames a second on their way to the screen, in gold in the strip from the loop's
/// start to Stop in every take, where the same take unrecorded, or with screencapture recording a still corner of the
/// screen, dropped none from the drag to Stop (2026-10-13). The whole display is filtered, not this process's windows:
/// a capture of an app's windows draws a shared window's traffic lights as a screen sharing badge. What it keeps of the
/// frames is touched only on `queue`, where ScreenCaptureKit hands them over, and by `finish` through it.
private final class ReadmeStream: NSObject, SCStreamOutput, @unchecked Sendable {
    /// Twice the GIF's rate.
    static let fps = 30
    let movie: URL
    private let stream: SCStream
    private let width: Int, height: Int
    private let encoder = Process()
    private let input: FileHandle
    private let queue = DispatchQueue(label: "ai.ronar.nitido.readme-stream", qos: .userInitiated)
    /// The first frame's capture time, on the host clock (`CACurrentMediaTime`): the movie's start.
    private var firstAt: Double?
    /// Frames written so far; the next one is the movie's frame at this index.
    private var written = 0
    private var last: Data?
    private var failure: String?

    /// Records `rect` (top left origin, points) of the main screen into `movie` from now on.
    static func record(_ rect: CGRect, into movie: URL) async throws -> ReadmeStream {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else {
            throw ReelError.missing("the main display among ScreenCaptureKit's")
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.sourceRect = rect
        config.width = Int(rect.width * 2)
        config.height = Int(rect.height * 2)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = false
        config.queueDepth = 5
        config.captureResolution = .best
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        let recorder = try ReadmeStream(stream: stream, width: config.width, height: config.height, movie: movie)
        do {
            try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: recorder.queue)
            try await stream.startCapture()
        } catch {
            recorder.encoder.terminate()
            throw error
        }
        return recorder
    }

    private init(stream: SCStream, width: Int, height: Int, movie: URL) throws {
        self.stream = stream
        self.width = width
        self.height = height
        self.movie = movie
        let pipe = Pipe()
        input = pipe.fileHandleForWriting
        // A write after ffmpeg is gone fails (`failure`) instead of ending this process.
        _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
        try? FileManager.default.removeItem(at: movie)
        encoder.executableURL = URL(fileURLWithPath: MotionReel.ffmpeg)
        encoder.arguments = ["-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "bgra", "-video_size", "\(width)x\(height)",
                             "-framerate", "\(Self.fps)", "-i", "pipe:0", "-c:v", "libx264rgb", "-preset", "ultrafast", "-qp", "0",
                             movie.path]
        encoder.standardInput = pipe
        // Below the app's own work, which is what the take shows.
        encoder.qualityOfService = .utility
        super.init()
        try encoder.run()
        try? pipe.fileHandleForReading.close()
    }

    /// The movie's start on the host clock (`CACurrentMediaTime`): its first frame's capture time. Nil before one came.
    var movieStart: Double? { queue.sync { firstAt } }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, failure == nil, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer),
              let info = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              info[.status] as? Int == SCFrameStatus.complete.rawValue else { return }
        let at = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let first = firstAt ?? at
        firstAt = first
        let frame = packed(pixels)
        let index = Int(((at - first) * Double(Self.fps)).rounded())
        // The screen showed the last frame until this one.
        if let last { while written < index, failure == nil { write(last) } }
        // A frame that comes within the same slot as the one before waits for the next slot, as the newest.
        if written == index { write(frame) }
        last = frame
    }

    /// Ends the recording at `end` (host clock), the last frame repeated up to it, and waits for ffmpeg to finish the
    /// movie. Throws if no frame came, a frame could not be written or ffmpeg failed.
    func finish(at end: Double) async throws {
        try await stream.stopCapture()
        let failed = queue.sync { () -> String? in
            if let firstAt, let last {
                let index = Int(((end - firstAt) * Double(Self.fps)).rounded())
                while written <= index, failure == nil { write(last) }
            }
            try? input.close()
            return failure ?? (firstAt == nil ? "ScreenCaptureKit sent no frame of the take" : nil)
        }
        while encoder.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        if let failed { throw ReelError.tool(failed) }
        guard encoder.terminationStatus == 0 else { throw ReelError.tool("ffmpeg exited \(encoder.terminationStatus) writing \(movie.path)") }
    }

    /// Ends the recording at once and deletes it: a take that failed, or saw something other than Nítido, keeps nothing.
    func abandon() {
        stream.stopCapture { _ in }
        encoder.terminate()
        queue.async { [input, movie] in
            try? input.close()
            try? FileManager.default.removeItem(at: movie)
        }
    }

    private func write(_ frame: Data) {
        do {
            try input.write(contentsOf: frame)
            written += 1
        } catch {
            failure = "ffmpeg stopped taking the take's frames: \(error)"
        }
    }

    /// The frame's pixels, row after row without the buffer's padding.
    private func packed(_ pixels: CVPixelBuffer) -> Data {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        var data = Data(count: width * height * 4)
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return data }
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        let rows = min(height, CVPixelBufferGetHeight(pixels)), bytes = min(width, CVPixelBufferGetWidth(pixels)) * 4
        data.withUnsafeMutableBytes { out in
            guard let to = out.baseAddress else { return }
            for row in 0..<rows { memcpy(to + row * width * 4, base + row * stride, bytes) }
        }
        return data
    }
}

extension ReelDirector {
    /// The README's take: the window at `corner`, the GIF's rect around the window's largest frame (the picture with the
    /// strip). Times are from the window's first frame on screen.
    func playReadme() async throws -> ReadmeTake {
        // The picture: 1440×900 px at 2x, so 720×450 pt and the window 720×527 with its title bar and strip.
        let width = 1440, height = 900
        policy.rollsFigures = false
        defer { policy.rollsFigures = true }
        // The feed stands in for ScreenCaptureKit, whose frames come at the display's refresh whatever the app's timers
        // do. This process is never the active app, so the system may coalesce its timers, the feed's 16 ms sleeps among
        // them: the take holds them to their time, as a capture's frames are.
        let precise = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Recording the README's reel")
        defer { ProcessInfo.processInfo.endActivity(precise) }
        let corner = CGPoint(x: 40, y: 82)
        let area = CGRect(x: corner.x - 40, y: corner.y - 26, width: 720 + 80, height: 527 + 26 + 44)
        raiseBackdrop(CGRect(x: 0, y: area.minY, width: area.maxX + 40, height: area.height + 40))

        let window = ReelWindow(visual: ReelRoot(app: shareApp, policy: policy), corner: corner)
        self.share = window
        try await pause(1.2)
        // The launch plays from the moment the window is on screen: Welcome built anew while the window is away.
        window.window.orderOut(nil)
        Instantly.run { shareApp.screen = .share }
        try await pause(0.2)
        shareApp.launchPlayed = false
        Instantly.run { shareApp.screen = .welcome }
        try prepare(width: width, height: height)
        try await pause(0.4)

        let pointer = ReelPointer()
        defer { pointer.close() }
        // The recording leaves the real pointer out, but one resting over the take would still be over its windows: it is
        // moved aside for the take, and put back after.
        let screen = NSScreen.main!.frame
        let resting = CGPoint(x: NSEvent.mouseLocation.x, y: screen.height - NSEvent.mouseLocation.y)
        let parked = area.insetBy(dx: -24, dy: -24).contains(resting)
        if parked { CGWarpMouseCursorPosition(CGPoint(x: min(screen.width - 80, area.maxX + 200), y: min(screen.height - 80, area.maxY + 100))) }
        defer { if parked { CGWarpMouseCursorPosition(resting) } }
        let recorder = try await ReadmeStream.record(area, into: MotionReel.clips.appendingPathComponent("readme.mkv"))
        // Only Nítido may be recorded. The screen is the person's while the take runs: should another app's window come
        // over the GIF's rect, or the screen go to another Space, the recording is deleted and the take fails (a take
        // on 2026-10-12 recorded another app after its windows left the screen with their Space). So is it when the
        // take fails for any other reason, as the screen goes on being recorded after the reel's windows are gone.
        var finished = false
        defer { if !finished { recorder.abandon() } }
        let ground = try XCTUnwrap(backdrop)
        watch = { if let other = Self.intruder(over: area, backdrop: ground) { throw ReelError.intruded(other) } }
        defer { watch = nil }
        try await pause(0.9)

        window.window.orderFrontRegardless()
        let t0 = CACurrentMediaTime()
        func at(_ t: Double) async throws {
            let wait = t0 + t - CACurrentMediaTime()
            if wait > 0 { try await pause(wait) }
        }
        var tip = CGPoint(x: 470, y: 330)
        /// The arrow from where it is to `to` over `seconds`, as a hand moves (the system ease-in-out), the window told of
        /// every step: moves, or drags while the button is down.
        func glide(to target: CGPoint, over seconds: Double, dragging: Bool = false) async throws {
            let from = tip, curve = Theme.Motion.Curve(Theme.Motion.systemEaseInOut, seconds)
            let start = CACurrentMediaTime()
            while true {
                let k = curve.progress(at: CACurrentMediaTime() - start)
                tip = CGPoint(x: from.x + (target.x - from.x) * k, y: from.y + (target.y - from.y) * k)
                pointer.move(to: window.screenPoint(tip))
                window.send(dragging ? .leftMouseDragged : .mouseMoved, at: tip)
                if k >= 1 { break }
                try await pause(0.016)
            }
        }
        /// The longest gap between two steps of a stroke or a drag: how long the main thread was held.
        var longestStep: CFTimeInterval = 0
        /// The arrow along `path` (0 to 1) over `seconds`, the button down: a stroke or a drag.
        func trace(over seconds: Double, _ path: (Double) -> CGPoint) async throws {
            let start = CACurrentMediaTime()
            var last = start
            while true {
                let now = CACurrentMediaTime()
                longestStep = max(longestStep, now - last); last = now
                let u = min(1, (now - start) / seconds)
                tip = path(u)
                pointer.move(to: window.screenPoint(tip))
                window.send(.leftMouseDragged, at: tip)
                if u >= 1 { break }
                try await pause(0.016)
            }
        }

        // 0 s: the launch. 2.1 s: the arrow comes to Share and presses it; the picker's card.
        try await at(2.1)
        let shareButton = window.elementFrame(role: .button, label: "Share") ?? CGRect(x: 206, y: 216, width: 96, height: 40)
        pointer.move(to: window.screenPoint(tip))
        pointer.show(true)
        let sessions = sources.count
        try await glide(to: CGPoint(x: shareButton.midX + 6, y: shareButton.midY + 4), over: 0.6)
        try await at(2.95)
        window.send(.leftMouseDown, at: tip)
        try await at(3.13)
        window.send(.leftMouseUp, at: tip)
        try await waitUntil("Share opens a session") { self.sources.count > sessions }
        try await at(3.4)
        pointer.show(false)

        // 4.3 s: the pick. The window grows to the picture; the strip, the panels and the code follow.
        try await at(4.3)
        try pick(width: width, height: height)
        let model = try XCTUnwrap(shareApp.share)
        try await waitUntil("the sharer listens") { model.listeningPort != nil }
        // The sharer's dropped frames by stretch, printed at the end: the strip shows them in gold.
        var drops: [(String, Int)] = []
        var dropsSoFar = model.droppedFramesTotal
        func noteDrops(_ stretch: String) {
            drops.append((stretch, model.droppedFramesTotal - dropsSoFar)); dropsSoFar = model.droppedFramesTotal
        }

        // 6 s: a viewer pairs over the loopback link; the sharer's panel takes it in, and the ring draws.
        try await at(6.0)
        let sharer = Peer(id: "loopback", name: model.advertisedName ?? model.name, keyName: model.name,
                          endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: model.listeningPort!)!))
        // Named apart from the sharer, which runs on this Mac too: the panel's row and the pointer's label read as a
        // second Mac.
        let viewer = ViewModel(startingDiscovery: false, name: "Ronald’s MacBook Air")
        defer { viewer.disconnect() }
        viewer.peers = [sharer]
        viewer.select(sharer)
        viewer.code = model.code
        viewer.connect()
        try await waitUntil("the viewer is connected") { viewer.state == .connected && model.viewerName != nil }

        // 7.5 s: a gold ring drawn round "Monday" in the document, by the pointer.
        let doc = CGPoint(x: Double(width) * 0.30 + 56, y: Double(height) * 0.04 + 96 + 70)   // px, the first line's top left
        let body = NSFont.systemFont(ofSize: 24)
        let before = NSAttributedString(string: "The first public build goes out on ", attributes: [.font: body]).size().width
        let word = NSAttributedString(string: "Monday", attributes: [.font: body]).size().width
        let ring = CGPoint(x: (doc.x + before + word / 2) / 2, y: (doc.y + 15) / 2)
        let rx = word / 4 + 9, ry = 11.5
        func loop(_ u: Double) -> CGPoint {
            // A little over a turn, clockwise from the left, a hand's ellipse: wider on its way back.
            let a = Double.pi + u * 2.2 * Double.pi
            let grow = 1 + 0.12 * u
            return CGPoint(x: ring.x + rx * grow * cos(a), y: ring.y + ry * grow * sin(a) + 2 * u)
        }
        try await at(7.4)
        tip = CGPoint(x: ring.x - 60, y: ring.y + 70)
        pointer.move(to: window.screenPoint(tip))
        pointer.show(true)
        try await glide(to: loop(0), over: 0.45)
        window.send(.leftMouseDown, at: tip)
        try await trace(over: 0.8, loop)
        window.send(.leftMouseUp, at: tip)

        // 8.3 s: the viewer ticks "Open questions" in cream, just past the heading; its pointer, a gold dot with its
        // name 12 pt to its right, leads. The pointer comes along the heading's line from the right and the tick keeps to
        // it (the heading's line is 362 to 396 px, the line above ends 311 px down, the item below starts 416), so the
        // name always lies on blank paper: an underline put it between the heading and the line under it, over both,
        // which read as a collision.
        let heading = NSAttributedString(string: "Open questions", attributes: [.font: NSFont.systemFont(ofSize: 28, weight: .semibold)]).size().width
        let row = doc.y + 4 * 40
        let a = CGPoint(x: doc.x + heading + 18, y: row), b = CGPoint(x: a.x + 20, y: row + 30), c = CGPoint(x: b.x + 58, y: row - 24)
        func normalized(_ p: CGPoint) -> (x: Float, y: Float) { (Float(p.x / CGFloat(width)), Float(p.y / CGFloat(height))) }
        func tick(_ u: Double) -> StrokePoint {
            // Down to the foot over the first third, then up and out with a slight bow, as a hand ticks.
            let split = 0.31
            let p: CGPoint
            if u < split {
                let k = u / split
                p = CGPoint(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k)
            } else {
                let k = (u - split) / (1 - split)
                p = CGPoint(x: b.x + (c.x - b.x) * k, y: b.y + (c.y - b.y) * k - 6 * sin(k * .pi))
            }
            let n = normalized(p)
            return StrokePoint(x: n.x, y: n.y, pressure: 1, tMs: UInt32(u * 480))
        }
        let theirs = Task { @MainActor in
            let from = normalized(CGPoint(x: a.x + 240, y: row + 14)), to = normalized(a)
            let arrive = Theme.Motion.Curve(Theme.Motion.systemEaseInOut, 1)
            for i in 0...20 {
                let k = Float(arrive.progress(at: Double(i) / 20))
                viewer.ink.cursorMoved(Cursor(x: from.x + (to.x - from.x) * k, y: from.y + (to.y - from.y) * k, visible: true))
                try? await Task.sleep(for: .milliseconds(16))
            }
            let id = viewer.ink.beginLocal(tick(0))
            for i in 1...30 {
                let p = tick(Double(i) / 30)
                viewer.ink.appendLocal(id, [p])
                viewer.ink.cursorMoved(Cursor(x: p.x, y: p.y, visible: true))
                try? await Task.sleep(for: .milliseconds(16))
            }
            viewer.ink.endLocal(id)
            try? await Task.sleep(for: .milliseconds(700))
            viewer.ink.cursorMoved(Cursor(x: 0, y: 0, visible: false))
        }

        // 8.9 s: the arrow goes to the codec loop's switch and turns it on: the panel unfolds, a light runs up the divider.
        guard let toggle = window.control(NSSwitch.self)?.frame else { throw ReelError.missing("the Codec loop switch") }
        try await at(8.8)
        try await glide(to: CGPoint(x: toggle.midX + 3, y: toggle.midY + 3), over: 0.5)
        try await at(9.45)
        model.loopToggledAt = CACurrentMediaTime()
        withAnimation(Theme.Motion.move.animation) { model.loopback = true }

        // 10.1 s: the divider's dot, held (it grows to 1.3), dragged left, right, and let go in the middle, before the
        // gold stroke starts to fade.
        try await at(10.1)
        noteDrops("pick to drag")
        longestStep = 0
        let dotY = 450 - DividerHandle.dotInset
        try await glide(to: CGPoint(x: 360, y: dotY), over: 0.4)
        window.send(.leftMouseDown, at: tip)
        try await pause(0.1)
        let sweep = Theme.Motion.Curve(Theme.Motion.systemEaseInOut, 1)
        try await trace(over: 0.55) { u in CGPoint(x: 360 - 160 * sweep.progress(at: u), y: dotY) }
        try await trace(over: 0.85) { u in CGPoint(x: 200 + 330 * sweep.progress(at: u), y: dotY) }
        try await trace(over: 0.45) { u in CGPoint(x: 530 - 170 * sweep.progress(at: u), y: dotY) }
        window.send(.leftMouseUp, at: tip)
        noteDrops("drag")
        let dragStep = longestStep
        await theirs.value

        // 12.6 s: the strokes fade, 4 s after their last points. 14.6 s: the quality comes down to 4 Mbps by the slider.
        guard let found = window.control(NSSlider.self) else { throw ReelError.missing("the quality slider") }
        let (track, slider) = found
        func knob(_ mbps: Double) -> CGPoint {
            let k = (mbps - ShareModel.qualityRange.lowerBound) / (ShareModel.qualityRange.upperBound - ShareModel.qualityRange.lowerBound)
            return CGPoint(x: slider.minX + track.knobThickness / 2 + (slider.width - track.knobThickness) * k, y: slider.midY + 1)
        }
        try await at(14.6)
        try await glide(to: knob(model.qualityMbps), over: 0.45)
        let from = model.qualityMbps
        let down = CACurrentMediaTime()
        while true {
            let k = Theme.Motion.Curve(Theme.Motion.systemEaseInOut, 0.6).progress(at: CACurrentMediaTime() - down)
            let mbps = (from + (4 - from) * k).rounded()
            if mbps != model.qualityMbps { model.qualityMbps = mbps }
            tip = knob(from + (4 - from) * k)
            pointer.move(to: window.screenPoint(tip))
            if k >= 1 { break }
            try await pause(0.016)
        }

        // 16 s: the loop off by its switch, where the unfolded panel has it now; the arrow leaves. 17.3 s: Stop, back to
        // Welcome's card.
        try await at(16.0)
        guard let unfolded = window.control(NSSwitch.self)?.frame else { throw ReelError.missing("the Codec loop switch") }
        try await glide(to: CGPoint(x: unfolded.midX + 3, y: unfolded.midY + 3), over: 0.5)
        try await at(16.6)
        model.loopToggledAt = CACurrentMediaTime()
        withAnimation(LoopbackPanel.Unfold.fold.animation) { model.loopback = false }
        try await at(17.0)
        pointer.show(false)
        try await at(ReadmeTake.stop)
        noteDrops("drag to stop")
        print("README take: sharer's dropped frames " + drops.map { "\($0.0) \($0.1)" }.joined(separator: ", ")
              + String(format: "; longest step of the drag %.1f ms", dragStep * 1000))
        shareApp.confirmedStop()
        try await at(ReadmeTake.opening + ReadmeTake.seconds + 0.4)
        try await recorder.finish(at: CACurrentMediaTime())
        finished = true
        let movieStart = try XCTUnwrap(recorder.movieStart)

        // The codec loop's still, after the take so its capture costs the take nothing: a share again, the loop on at once
        // (as ⌘L does), the strip a full second in and its figures changing without their roll, and the window alone at
        // the screen's scale, without its shadow.
        policy.still = true
        defer { policy.still = false }
        let shares = sources.count
        shareApp.startShare()
        try await waitUntil("Share opens a session again") { self.sources.count > shares }
        try pick(width: width, height: height)
        let again = try XCTUnwrap(shareApp.share)
        try await waitUntil("the share captures again") { again.state == .capturing }
        Instantly.run { again.loopback = true }
        try await pause(2.2)
        try MotionReel.run("/usr/sbin/screencapture", ["-x", "-o", "-l", "\(window.window.windowNumber)",
                                                       MotionReel.clips.appendingPathComponent("codec-loop.png").path])
        feed?.cancel(); feed = nil
        return ReadmeTake(movie: recorder.movie, rect: area, launch: t0 - movieStart)
    }

    /// What, other than this process's windows, shows over `rect` (top left origin, points): the backdrop off the
    /// screen (another Space, or a full-screen app, is showing), or the first window of another app above it there.
    /// The clear windows that screencapture and screencaptureui put over the whole screen do not count, nor does
    /// Notification Center's, also over the whole screen, which draws its banners and its panel at the right edge, away
    /// from the take on the left. Nil while only Nítido can be recorded.
    static func intruder(over rect: CGRect, backdrop: NSWindow) -> String? {
        guard backdrop.isOnActiveSpace, backdrop.occlusionState.contains(.visible) else { return "another Space or a full-screen app" }
        let own = ProcessInfo.processInfo.processIdentifier
        let above = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow, .excludeDesktopElements], CGWindowID(backdrop.windowNumber))
        for info in (above as? [[String: Any]]) ?? [] {
            guard let pid = info[kCGWindowOwnerPID as String] as? Int32, pid != own,
                  info[kCGWindowOwnerName as String] as? String != "screencapture",
                  !["com.apple.screencaptureui", "com.apple.notificationcenterui"].contains(NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""),
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary), frame.intersects(rect) else { continue }
            return "a window of \(info[kCGWindowOwnerName as String] as? String ?? "another app") at \(frame)"
        }
        return nil
    }
}
