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
    public var onPresented: (@MainActor @Sendable (_ captureHostTimeNs: UInt64, _ presentedAt: Double) -> Void)?
    public private(set) var contentPixelSize: CGSize = .zero

    private let device = MTLCreateSystemDefaultDevice()!
    private lazy var commandQueue = device.makeCommandQueue()!
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private lazy var ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false, .workingColorSpace: colorSpace])
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

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

    public func present(_ pixelBuffer: CVPixelBuffer, captureHostTimeNs: UInt64) {
        contentPixelSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        let target = metalLayer.drawableSize
        guard target.width > 0, target.height > 0,
              let drawable = metalLayer.nextDrawable(),
              let command = commandQueue.makeCommandBuffer() else { return }

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
            log.error("render: \(error.localizedDescription)")
            return
        }
        let callback = onPresented
        drawable.addPresentedHandler { presented in
            let at = presented.presentedTime
            Task { @MainActor in callback?(captureHostTimeNs, at) }
        }
        command.present(drawable)
        command.commit()
    }
}

/// Lets a model push frames straight to the view, bypassing SwiftUI's update cycle.
@MainActor
public final class FrameSink {
    public weak var view: VideoView?
    public var onPresented: (@MainActor @Sendable (UInt64, Double) -> Void)?
    public init() {}
    public func push(_ pixelBuffer: CVPixelBuffer, captureHostTimeNs: UInt64) {
        guard let view else { return }
        view.onPresented = onPresented
        view.present(pixelBuffer, captureHostTimeNs: captureHostTimeNs)
    }
}

public struct VideoSurface: NSViewRepresentable {
    public let sink: FrameSink
    public init(sink: FrameSink) { self.sink = sink }
    public func makeNSView(context: Context) -> VideoView { let v = VideoView(frame: .zero); sink.view = v; return v }
    public func updateNSView(_ view: VideoView, context: Context) { sink.view = view }
}
