import AppKit
import SwiftUI
import Metal
import CoreImage
import CoreVideo
import QuartzCore
import os

private let log = Logger(subsystem: "ai.ronar.nitido", category: "video")

/// Draws pixel buffers 1:1 when the drawable is large enough, downscales with Lanczos otherwise, never upscales.
public final class VideoView: NSView {
    /// Why a frame was not drawn. `.hidden` is a deliberate pause; every other case is a dropped frame.
    public enum Drop: Sendable, Hashable {
        /// The window is minimized, fully covered, hidden or not laid out yet; no drawable was requested.
        case hidden
        /// The compositor still holds the earlier drawables; asking for another would block the main thread.
        case backlog
        /// `nextDrawable()` returned nil after its timeout.
        case noDrawable
        /// The frame was rendered but its drawable was discarded instead of shown.
        case notPresented
        /// Metal or CoreImage failed to render the frame.
        case failed(String)
    }

    public var onPresented: (@MainActor @Sendable (_ captureHostTimeNs: UInt64, _ presentedAt: Double) -> Void)?
    /// Called on the main actor for every frame that was not drawn.
    public var onDropped: (@MainActor @Sendable (Drop) -> Void)?
    public private(set) var contentPixelSize: CGSize = .zero

    private let device = MTLCreateSystemDefaultDevice()!
    private lazy var commandQueue = device.makeCommandQueue()!
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private lazy var ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false, .workingColorSpace: colorSpace])
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    /// Frames committed whose drawable has not been presented or discarded yet.
    private var inFlight = 0
    /// Last commit or drawable return; a backlog with no movement for a second means a lost handler.
    private var lastDrawableActivity: CFTimeInterval = 0
    /// Drops not logged yet, by reason. Logged at most once a second so a long stall does not flood the log.
    private var unloggedDrops: [Drop: Int] = [:]
    private var lastDropLog: CFTimeInterval = 0

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    public override func makeBackingLayer() -> CALayer {
        let l = CAMetalLayer()
        l.device = device
        l.pixelFormat = .bgra8Unorm
        l.framebufferOnly = false
        // Bounded wait: a nil drawable after one second instead of a main thread blocked indefinitely.
        l.allowsNextDrawableTimeout = true
        l.isOpaque = true
        l.colorspace = colorSpace
        l.backgroundColor = CGColor(srgbRed: 8 / 255, green: 9 / 255, blue: 12 / 255, alpha: 1)
        return l
    }

    public override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); updateDrawableSize() }
    public override func layout() { super.layout(); updateDrawableSize() }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
    }

    /// The point size at which `pixelSize` shows 1:1 on this view's screen.
    public func pointSize(forPixelSize px: CGSize) -> CGSize {
        let s = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        return CGSize(width: px.width / s, height: px.height / s)
    }

    /// True while the window can actually show the picture. A minimized or fully covered window gets no
    /// drawables back from the compositor, and `nextDrawable()` would then stall the main thread.
    private var isVisibleOnScreen: Bool {
        guard let window, window.isVisible, !window.isMiniaturized else { return false }
        return window.occlusionState.contains(.visible)
    }

    public func present(_ pixelBuffer: CVPixelBuffer, captureHostTimeNs: UInt64) {
        contentPixelSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        let target = metalLayer.drawableSize
        guard target.width > 0, target.height > 0, isVisibleOnScreen else { dropped(.hidden); return }
        // One drawable is on screen and one may be queued; only ask for another when a third is free,
        // so nextDrawable() returns at once instead of blocking the main thread.
        if inFlight >= max(1, metalLayer.maximumDrawableCount - 1) {
            guard CACurrentMediaTime() - lastDrawableActivity > 1 else { dropped(.backlog); return }
            log.error("No drawable came back for 1 s with \(self.inFlight, privacy: .public) frames in flight; resetting the count")
            inFlight = 0
        }
        guard let drawable = metalLayer.nextDrawable() else { dropped(.noDrawable); return }
        guard let command = commandQueue.makeCommandBuffer() else {
            dropped(.failed("Metal could not create a command buffer."))
            return
        }

        var image = CIImage(cvPixelBuffer: pixelBuffer)
        let fit = min(target.width / contentPixelSize.width, target.height / contentPixelSize.height)
        if fit < 1, let lanczos = CIFilter(name: "CILanczosScaleTransform") {
            lanczos.setValue(image, forKey: kCIInputImageKey)
            lanczos.setValue(fit, forKey: kCIInputScaleKey)
            lanczos.setValue(1.0, forKey: kCIInputAspectRatioKey)
            image = lanczos.outputImage ?? image
        }
        let shown = image.extent.size
        image = image.transformed(by: CGAffineTransform(translationX: ((target.width - shown.width) / 2).rounded(),
                                                         y: ((target.height - shown.height) / 2).rounded()))
        let bounds = CGRect(origin: .zero, size: target)
        let background = CIImage(color: CIColor(red: 8 / 255, green: 9 / 255, blue: 12 / 255)).cropped(to: bounds)
        let destination = CIRenderDestination(mtlTexture: drawable.texture, commandBuffer: command)
        destination.colorSpace = colorSpace
        do {
            try ciContext.startTask(toRender: image.composited(over: background), from: bounds, to: destination, at: .zero)
        } catch {
            dropped(.failed(error.localizedDescription))
            return
        }
        let callback = onPresented
        drawable.addPresentedHandler { [weak self] presented in
            let at = presented.presentedTime
            Task { @MainActor in
                guard let self else { return }
                self.drawableReturned()
                // A discarded drawable reports 0: count it as dropped, never as a display at time zero.
                if at > 0 { callback?(captureHostTimeNs, at) } else { self.dropped(.notPresented) }
            }
        }
        command.addCompletedHandler { [weak self] buffer in
            guard let error = buffer.error else { return }
            let reason = error.localizedDescription
            Task { @MainActor in self?.dropped(.failed(reason)) }
        }
        command.present(drawable)
        command.commit()
        inFlight += 1
        lastDrawableActivity = CACurrentMediaTime()
        flushDropLog(force: false)
    }

    private func drawableReturned() {
        inFlight = max(0, inFlight - 1)
        lastDrawableActivity = CACurrentMediaTime()
    }

    /// Reports a frame that was not drawn and logs it (rate limited, with counts).
    private func dropped(_ drop: Drop) {
        unloggedDrops[drop, default: 0] += 1
        flushDropLog(force: false)
        onDropped?(drop)
    }

    private func flushDropLog(force: Bool) {
        guard !unloggedDrops.isEmpty else { return }
        let now = CACurrentMediaTime()
        guard force || now - lastDropLog >= 1 else { return }
        lastDropLog = now
        for (drop, count) in unloggedDrops {
            switch drop {
            case .hidden:
                log.info("Window not visible: skipped \(count, privacy: .public) frames without drawing")
            case .backlog:
                log.error("Dropped \(count, privacy: .public) frames: the compositor still held the earlier drawables")
            case .noDrawable:
                log.error("Dropped \(count, privacy: .public) frames: no drawable became available")
            case .notPresented:
                log.error("Dropped \(count, privacy: .public) frames: rendered but never presented")
            case .failed(let reason):
                log.error("Dropped \(count, privacy: .public) frames: render failed: \(reason, privacy: .public)")
            }
        }
        unloggedDrops.removeAll()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { flushDropLog(force: true) }
    }
}

/// Lets a model push frames straight to the view, bypassing SwiftUI's update cycle.
@MainActor
public final class FrameSink {
    public weak var view: VideoView?
    public var onPresented: (@MainActor @Sendable (UInt64, Double) -> Void)?
    public var onDropped: (@MainActor @Sendable (VideoView.Drop) -> Void)?
    public init() {}
    public func push(_ pixelBuffer: CVPixelBuffer, captureHostTimeNs: UInt64) {
        guard let view else { onDropped?(.hidden); return }
        view.onPresented = onPresented
        view.onDropped = onDropped
        view.present(pixelBuffer, captureHostTimeNs: captureHostTimeNs)
    }
}

public struct VideoSurface: NSViewRepresentable {
    public let sink: FrameSink
    public init(sink: FrameSink) { self.sink = sink }
    public func makeNSView(context: Context) -> VideoView { let v = VideoView(frame: .zero); sink.view = v; return v }
    public func updateNSView(_ view: VideoView, context: Context) { sink.view = view }
}
