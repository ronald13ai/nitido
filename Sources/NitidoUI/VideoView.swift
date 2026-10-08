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
        /// The frame waited for a drawable (the compositor still held the earlier ones, and asking for another
        /// would block the main thread), or was held back because it waited through a refresh, and a newer frame
        /// replaced it before it could be drawn.
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
    /// The display the picture is on: the window's backing scale and its screen's visible frame, each time the view
    /// enters a window, the window changes screen or backing scale, or the screens change (`reportDisplay`).
    var onDisplayChange: ((_ scale: CGFloat, _ visibleFrame: CGRect?) -> Void)?
    public private(set) var contentPixelSize: CGSize = .zero

    private let device = MTLCreateSystemDefaultDevice()!
    private lazy var commandQueue = device.makeCommandQueue()!
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private lazy var ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false, .workingColorSpace: colorSpace])
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    /// Holds the newest frame, caps frames in flight and redraws after a resize or when the window shows again.
    let pacer = FramePacer()
    /// The window whose occlusion, deminiaturize and screen-change notifications this view observes.
    private weak var observedWindow: NSWindow?
    /// Drops not logged yet, by reason. Logged at most once a second so a long stall does not flood the log.
    private var unloggedDrops: [Drop: Int] = [:]
    private var lastDropLog: CFTimeInterval = 0
    /// nextDrawable() calls that blocked the main thread since the last log line, and the longest of them.
    private var slowDrawableWaits = 0
    private var longestDrawableWait: CFTimeInterval = 0
    /// A wait inside nextDrawable() longer than this blocked the main thread noticeably (a quarter of a 60 Hz frame).
    private static let slowDrawableWait: CFTimeInterval = 0.004

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        pacer.host = self
        // A screen's visible frame changes with the Dock and the menu bar, and its scale with the display's mode.
        NotificationCenter.default.addObserver(self, selector: #selector(displayMayHaveChanged(_:)),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
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

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
        reportDisplay()
    }
    public override func layout() { super.layout(); updateDrawableSize() }

    /// Sizes the drawable to the view in pixels. A real change makes the pacer draw the held frame again, since
    /// the layer would otherwise stretch the last drawable to the new bounds until the source changes.
    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        if metalLayer.drawableSize != size { metalLayer.drawableSize = size }
        pacer.drawableSize = size
    }

    /// Tells `onDisplayChange` the display the picture is on; nothing while the view is in no window.
    func reportDisplay() {
        guard let window else { return }
        onDisplayChange?(window.backingScaleFactor, window.screen?.visibleFrame)
    }

    @objc private func displayMayHaveChanged(_ note: Notification) { reportDisplay() }

    /// `compareWith` is the raw frame shown left of `dividerAt` (0...1); the main buffer is shown on the right.
    public func present(_ pixelBuffer: CVPixelBuffer, captureHostTimeNs: UInt64, compareWith raw: CVPixelBuffer? = nil, dividerAt divider: CGFloat = 0.5) {
        contentPixelSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        pacer.present(FramePacer.Frame(pixelBuffer: pixelBuffer, captureHostTimeNs: captureHostTimeNs, compareWith: raw, divider: divider))
        flushDropLog(force: false)
    }

    /// Lets go of the frame kept for redraws, so its buffer returns to the capture pool (the share stopped).
    public func releaseHeldFrame() { pacer.releaseHeldFrame() }

    /// Loopback: the comparison on the frame kept for redraws splits at `divider` (0...1) from now on. The source's
    /// next frame shows it; a still source's held frame is drawn again once that frame is overdue.
    public func moveDivider(to divider: CGFloat) { pacer.moveDivider(to: divider) }

    /// Loopback off: `pixelBuffer` (the newest raw frame) is shown alone in place of the comparison, drawn at once.
    public func endComparison(showing pixelBuffer: CVPixelBuffer, captureHostTimeNs: UInt64) {
        contentPixelSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        pacer.replaceHeld(with: FramePacer.Frame(pixelBuffer: pixelBuffer, captureHostTimeNs: captureHostTimeNs))
    }

    /// Reports a frame that was not drawn and logs it (rate limited, with counts).
    private func dropped(_ drop: Drop) {
        unloggedDrops[drop, default: 0] += 1
        flushDropLog(force: false)
        onDropped?(drop)
    }

    private func flushDropLog(force: Bool) {
        guard !unloggedDrops.isEmpty || slowDrawableWaits > 0 else { return }
        let now = CACurrentMediaTime()
        guard force || now - lastDropLog >= 1 else { return }
        lastDropLog = now
        if slowDrawableWaits > 0 {
            log.error("nextDrawable() blocked the main thread \(self.slowDrawableWaits, privacy: .public) times, the longest for \(self.longestDrawableWait * 1000, format: .fixed(precision: 1), privacy: .public) ms")
            slowDrawableWaits = 0
            longestDrawableWait = 0
        }
        for (drop, count) in unloggedDrops {
            switch drop {
            case .hidden:
                log.info("Window not visible: skipped \(count, privacy: .public) frames without drawing")
            case .backlog:
                log.error("Dropped \(count, privacy: .public) frames: replaced by a newer frame while waiting for a drawable")
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
        let center = NotificationCenter.default
        if let observedWindow {
            center.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: observedWindow)
            center.removeObserver(self, name: NSWindow.didDeminiaturizeNotification, object: observedWindow)
            center.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: observedWindow)
        }
        observedWindow = window
        guard let window else {
            // Out of the window: hand the held buffer back to the capture pool and write out pending drop counts.
            pacer.releaseHeldFrame()
            flushDropLog(force: true)
            return
        }
        center.addObserver(self, selector: #selector(windowMayHaveBecomeVisible(_:)),
                           name: NSWindow.didChangeOcclusionStateNotification, object: window)
        center.addObserver(self, selector: #selector(windowMayHaveBecomeVisible(_:)),
                           name: NSWindow.didDeminiaturizeNotification, object: window)
        center.addObserver(self, selector: #selector(displayMayHaveChanged(_:)),
                           name: NSWindow.didChangeScreenNotification, object: window)
        reportDisplay()
    }

    /// Frames that arrived while the window was minimized, covered or hidden were kept, not drawn: show the newest.
    @objc private func windowMayHaveBecomeVisible(_ note: Notification) {
        if canShowFrames { pacer.redraw() }
    }
}

extension VideoView: FrameDrawing {
    /// True while the window can actually show the picture. A minimized or fully covered window gets no
    /// drawables back from the compositor, and `nextDrawable()` would then stall the main thread.
    var canShowFrames: Bool {
        guard let window, window.isVisible, !window.isMiniaturized else { return false }
        return window.occlusionState.contains(.visible)
    }

    var drawableCount: Int { metalLayer.maximumDrawableCount }

    func render(_ frame: FramePacer.Frame, kind: FramePacer.Kind) -> Drop? {
        let target = metalLayer.drawableSize
        let signpost = videoSignposter.beginInterval("nextDrawable")
        let asked = CACurrentMediaTime()
        let next = metalLayer.nextDrawable()
        let waited = CACurrentMediaTime() - asked
        videoSignposter.endInterval("nextDrawable", signpost)
        log.debug("Draw \(kind == .live ? "live" : "redraw", privacy: .public) \(frame.captureHostTimeNs, privacy: .public): waited \(waited * 1000, format: .fixed(precision: 2), privacy: .public) ms for a drawable")
        if waited > Self.slowDrawableWait {
            slowDrawableWaits += 1
            longestDrawableWait = max(longestDrawableWait, waited)
        }
        guard let drawable = next else { return .noDrawable }
        guard let command = commandQueue.makeCommandBuffer() else { return .failed("Metal could not create a command buffer.") }

        let content = CGSize(width: CVPixelBufferGetWidth(frame.pixelBuffer), height: CVPixelBufferGetHeight(frame.pixelBuffer))
        var image = CIImage(cvPixelBuffer: frame.pixelBuffer)
        if let raw = frame.compareWith {
            let rawImage = CIImage(cvPixelBuffer: raw)
            let cut = (rawImage.extent.width * frame.divider).rounded()
            let left = rawImage.cropped(to: CGRect(x: 0, y: 0, width: cut, height: rawImage.extent.height))
            let line = CIImage(color: CIColor(red: 201 / 255, green: 168 / 255, blue: 106 / 255))
                .cropped(to: CGRect(x: cut - 1, y: 0, width: 2, height: rawImage.extent.height))
            image = line.composited(over: left.composited(over: image))
        }
        let fit = min(target.width / content.width, target.height / content.height)
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
            return .failed(error.localizedDescription)
        }
        let captureNs = frame.captureHostTimeNs
        drawable.addPresentedHandler { [weak self] presented in
            let at = presented.presentedTime
            Task { @MainActor in
                self?.pacer.drawableReturned(kind: kind, captureHostTimeNs: captureNs, presentedAt: at)
            }
        }
        command.addCompletedHandler { [weak self] buffer in
            guard let error = buffer.error else { return }
            let reason = error.localizedDescription
            Task { @MainActor in self?.dropped(.failed(reason)) }
        }
        command.present(drawable)
        command.commit()
        return nil
    }

    func framePresented(captureHostTimeNs: UInt64, at presentedAt: Double) {
        onPresented?(captureHostTimeNs, presentedAt)
    }

    func frameDropped(_ drop: Drop) { dropped(drop) }
}

/// Lets a model push frames straight to the view, bypassing SwiftUI's update cycle. It also says which display the
/// picture is on (`backingScale`, `visibleFrame`), observably, so the window's 1:1 size follows a move to another
/// display whatever else the window shows.
@MainActor @Observable
public final class FrameSink {
    @ObservationIgnored public weak var view: VideoView?
    @ObservationIgnored public var onPresented: (@MainActor @Sendable (UInt64, Double) -> Void)?
    @ObservationIgnored public var onDropped: (@MainActor @Sendable (VideoView.Drop) -> Void)?
    /// The backing scale of the window the view is in; nil until it is in one.
    public private(set) var backingScale: CGFloat?
    /// The visible frame of that window's screen; nil until the view is in a window on a screen.
    public private(set) var visibleFrame: CGRect?
    public init() {}

    /// The view's window moved to another display, or its display changed. Assigns only what changed, so SwiftUI
    /// re-evaluates the window's size only then.
    func displayChanged(scale: CGFloat?, visibleFrame: CGRect?) {
        if backingScale != scale { backingScale = scale }
        if self.visibleFrame != visibleFrame { self.visibleFrame = visibleFrame }
    }

    public func push(_ pixelBuffer: CVPixelBuffer, captureHostTimeNs: UInt64, compareWith raw: CVPixelBuffer? = nil, dividerAt divider: CGFloat = 0.5) {
        guard let view else { onDropped?(.hidden); return }
        view.onPresented = onPresented
        view.onDropped = onDropped
        view.present(pixelBuffer, captureHostTimeNs: captureHostTimeNs, compareWith: raw, dividerAt: divider)
    }
    /// Lets go of the frame the view keeps for redraws, handing its buffer back to the capture pool.
    public func releaseHeldFrame() { view?.releaseHeldFrame() }
    /// Moves the divider of the comparison on screen. A still source sends no new frame to carry the move, so the
    /// view draws the frame it keeps again once a frame is overdue; nothing when that frame shows no comparison.
    public func moveDivider(to divider: CGFloat) { view?.moveDivider(to: divider) }
    /// Ends the comparison on screen: `raw` is shown alone at once, without waiting for the source to change.
    public func endComparison(showing raw: CVPixelBuffer, captureHostTimeNs: UInt64) {
        guard let view else { return }
        view.onPresented = onPresented
        view.onDropped = onDropped
        view.endComparison(showing: raw, captureHostTimeNs: captureHostTimeNs)
    }
}

public struct VideoSurface: NSViewRepresentable {
    public let sink: FrameSink
    public init(sink: FrameSink) { self.sink = sink }
    public func makeNSView(context: Context) -> VideoView { let v = VideoView(frame: .zero); attach(v); return v }
    public func updateNSView(_ view: VideoView, context: Context) { attach(view) }

    /// The sink pushes frames to this view and hears which display it is on, taking the current one at once.
    private func attach(_ view: VideoView) {
        sink.view = view
        view.onDisplayChange = { [weak sink] scale, visibleFrame in sink?.displayChanged(scale: scale, visibleFrame: visibleFrame) }
        view.reportDisplay()
    }
}
