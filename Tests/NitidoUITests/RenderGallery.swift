import XCTest
import AppKit
import SwiftUI
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import QuartzCore
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

        let browsing = ViewModel(startingDiscovery: false)
        try offscreen("view-browsing-empty", ViewView(model: browsing))
        browsing.peers = Self.twoPeers
        try offscreen("view-browsing-two-peers", ViewView(model: browsing))
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
/// activation from the app in front.
private final class KeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
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
