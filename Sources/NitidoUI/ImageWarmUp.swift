import Metal
import CoreImage
import CoreVideo
import QuartzCore
import os

private let log = Logger(subsystem: "ai.ronar.nitido", category: "video")

/// Core Image compiles its kernels the first time a process draws with them: on a Mac where they were never compiled
/// (a first launch), the first decoded frame took 170 ms to draw and the first captured one some 9, on the main thread,
/// as the window starts growing to the picture (measured 2026-10-12, M5). Like `CodecWarmUp`, this draws once with each
/// kind of picture the view draws (captured BGRA and decoded 4:2:0, 1:1 and scaled down, alone and as the codec loop's
/// comparison) through a context of its own on the same device, off the main thread, while the person picks a window
/// or a Mac; the kernels are the process's, so the view's first frame finds them compiled.
enum ImageWarmUp {
    private static let started = OSAllocatedUnfairLock(initialState: false)

    /// Starts the warm-up on a background queue, the first time it is called in the process; does nothing after.
    static func start() {
        let first = started.withLock { was -> Bool in
            defer { was = true }
            return !was
        }
        guard first else { return }
        DispatchQueue.global(qos: .utility).async { _ = warm() }
    }

    /// Draws the view's kinds of picture once into a small texture and waits for the GPU. False if something could not
    /// be made or drawn (the view then compiles the kernels itself, as before).
    @discardableResult
    static func warm() -> Bool {
        let started = CACurrentMediaTime()
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return false }
        let context = VideoView.makeImageContext(device: device)
        let target = CGSize(width: 64, height: 40)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(target.width),
                                                                  height: Int(target.height), mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderWrite]
        guard let texture = device.makeTexture(descriptor: descriptor),
              let captured = buffer(width: 64, height: 40, format: kCVPixelFormatType_32BGRA),
              let decoded = buffer(width: 64, height: 40, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
              let large = buffer(width: 128, height: 80, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        else { return false }
        let frames = [
            FramePacer.Frame(pixelBuffer: captured, captureHostTimeNs: 0),
            FramePacer.Frame(pixelBuffer: decoded, captureHostTimeNs: 0, pictureSize: CGSize(width: 63, height: 39)),
            FramePacer.Frame(pixelBuffer: large, captureHostTimeNs: 0),
            FramePacer.Frame(pixelBuffer: decoded, captureHostTimeNs: 0, compareWith: captured, divider: 0.5),
        ]
        for frame in frames {
            guard let command = queue.makeCommandBuffer() else { return false }
            let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: command)
            destination.colorSpace = VideoView.colorSpace
            do {
                try context.startTask(toRender: VideoView.composed(frame, in: target), from: CGRect(origin: .zero, size: target),
                                      to: destination, at: .zero)
            } catch {
                log.info("image warm-up: \(error.localizedDescription, privacy: .public)")
                return false
            }
            command.commit()
            command.waitUntilCompleted()
            if command.error != nil { return false }
        }
        log.info("image warm-up took \((CACurrentMediaTime() - started) * 1000, format: .fixed(precision: 1), privacy: .public) ms")
        return true
    }

    private static func buffer(width: Int, height: Int, format: OSType) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary
        guard CVPixelBufferCreate(nil, width, height, format, attributes, &buffer) == kCVReturnSuccess else { return nil }
        return buffer
    }
}
