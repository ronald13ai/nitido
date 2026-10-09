import XCTest
import CoreVideo
import CoreImage
import Metal
@testable import NitidoCodec
@testable import NitidoUI

/// Captured colours through the codec and onto the screen, measured where the view draws them.
final class ColourTests: XCTestCase {
    private static let patch = 64, columns = 16, rows = 12

    /// The app's own palette, black, white, greys, primaries and secondaries, then a spread of others.
    private static let colours: [(r: UInt8, g: UInt8, b: UInt8)] = {
        var colours: [(r: UInt8, g: UInt8, b: UInt8)] = [
            (8, 9, 12), (14, 16, 21), (43, 46, 56), (58, 62, 74), (242, 243, 245), (201, 168, 106), (216, 186, 126),
            (243, 227, 186), (98, 195, 126), (224, 143, 143), (138, 143, 156), (0, 0, 0), (255, 255, 255),
            (32, 32, 32), (64, 64, 64), (128, 128, 128), (192, 192, 192), (224, 224, 224),
            (255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0), (0, 255, 255), (255, 0, 255),
        ]
        var seed: UInt32 = 12_345
        func next() -> UInt8 { seed = seed &* 1_664_525 &+ 1_013_904_223; return UInt8(seed >> 24) }
        while colours.count < columns * rows { colours.append((next(), next(), next())) }
        return colours
    }()

    /// A frame of flat patches, one per colour, in BGRA tagged sRGB as `CaptureSession` delivers it.
    private func patches() throws -> CVPixelBuffer {
        let width = Self.patch * Self.columns, height = Self.patch * Self.rows
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
        let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw XCTSkip("CVPixelBufferCreate failed: \(status)") }
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, VideoView.colorSpace, .shouldPropagate)
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let c = Self.colours[(y / Self.patch) * Self.columns + x / Self.patch]
                let p = base + y * stride + x * 4
                p[0] = c.b; p[1] = c.g; p[2] = c.r; p[3] = 0xff
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    /// `buffer` drawn the way the view draws it (`VideoView.image(of:)` in the view's Core Image context), into 8-bit
    /// sRGB, as the layer shows it.
    private func drawn(_ buffer: CVPixelBuffer, context: CIContext) -> [UInt8] {
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        context.render(VideoView.image(of: buffer), toBitmap: &pixels, rowBytes: width * 4,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .BGRA8, colorSpace: VideoView.colorSpace)
        return pixels
    }

    /// Mean and worst difference, in 8-bit code values per channel, between each patch's colour and the middle of the
    /// patch as drawn (the edges carry the 4:2:0 chroma of the patch next to it).
    private func error(of pixels: [UInt8]) -> (mean: Double, worst: Double) {
        let width = Self.patch * Self.columns
        var total = 0.0, worst = 0.0
        for (index, colour) in Self.colours.enumerated() {
            let left = (index % Self.columns) * Self.patch, top = (index / Self.columns) * Self.patch
            var sum = (r: 0.0, g: 0.0, b: 0.0), count = 0.0
            for y in (top + 16)..<(top + 48) {
                for x in (left + 16)..<(left + 48) {
                    let p = (y * width + x) * 4
                    sum.b += Double(pixels[p]); sum.g += Double(pixels[p + 1]); sum.r += Double(pixels[p + 2]); count += 1
                }
            }
            let off = [abs(sum.r / count - Double(colour.r)), abs(sum.g / count - Double(colour.g)), abs(sum.b / count - Double(colour.b))]
            total += off.reduce(0, +)
            worst = max(worst, off.max() ?? 0)
        }
        return (total / Double(Self.colours.count * 3), worst)
    }

    /// The two-Mac test's viewer showed the shared window's colours "quite similar but not exactly the same". The stream
    /// carried no colour tags, so the decoder took the capture's sRGB values for BT.709's transfer function and the
    /// sRGB layer shifted them by up to 12 code values. Captured, encoded, decoded and drawn as the view draws them,
    /// flat patches of sRGB colours now come back within a code value or two; drawn raw, they come back exactly.
    func testCapturedColoursReachTheScreenAsTheyWere() throws {
        let source = try patches()
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let context = VideoView.makeImageContext(device: device)
        let raw = error(of: drawn(source, context: context))
        XCTAssertEqual(raw.worst, 0, "the raw capture is drawn as it is")

        let encoder = try VideoEncoder(width: CVPixelBufferGetWidth(source), height: CVPixelBufferGetHeight(source),
                                       preferred: .hevc, bitsPerSecond: 40_000_000)
        defer { encoder.invalidate() }
        let frames = Box<[EncodedFrame]>([])
        let encoded = expectation(description: "encoded"); encoded.expectedFulfillmentCount = 4
        encoder.onFrame = { frames.append($0); encoded.fulfill() }
        for index in 0..<4 {
            XCTAssertTrue(encoder.encode(source, captureHostTimeNs: UInt64(index)))
            usleep(20_000)
        }
        wait(for: [encoded], timeout: 5)
        let stream = frames.value.sorted { $0.seq < $1.seq }
        let decoder = try VideoDecoder(config: try XCTUnwrap(stream.first?.videoConfig))
        defer { decoder.invalidate() }
        let decoded = Box<[DecodedFrame]>([])
        decoder.onFrame = { decoded.append($0) }
        for frame in stream { try decoder.decode(frame.videoFrame) }
        let picture = try XCTUnwrap(decoded.value.last?.pixelBuffer)

        let shown = error(of: drawn(picture, context: context))
        XCTAssertLessThan(shown.mean, 1.5, "mean error \(shown.mean) code values")
        XCTAssertLessThanOrEqual(shown.worst, 4, "worst error \(shown.worst) code values")
    }
}

extension ColourTests {
    /// One flat sRGB colour over a whole frame, in BGRA tagged sRGB as `CaptureSession` delivers it.
    private func flat(_ c: (r: UInt8, g: UInt8, b: UInt8), width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
        let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw XCTSkip("CVPixelBufferCreate failed: \(status)") }
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, VideoView.colorSpace, .shouldPropagate)
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let p = base + y * stride + x * 4
                p[0] = c.b; p[1] = c.g; p[2] = c.r; p[3] = 0xff
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    /// The evening's two-Mac test still saw colours "not exactly the same" on the Air after the colour tags. The
    /// decoder's pictures are 4:2:0 in video range (`VideoDecoder`): luma from 16 to 235. Read as full range, black would
    /// come out at 16 and white at 234, and a dark grey of 30 at 42 (measured, 2026-10-09). A dark grey, a light grey and
    /// a saturated red, each over a whole frame, captured, encoded, decoded and drawn as the view draws them into 8-bit
    /// sRGB, come back within two code values on every channel; the decoded picture says its range, matrix, primaries
    /// and transfer function.
    func testFlatColoursComeBackWithinTwoCodeValues() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let context = VideoView.makeImageContext(device: device)
        let width = 640, height = 360
        let colours: [(r: UInt8, g: UInt8, b: UInt8)] = [(30, 30, 30), (240, 240, 240), (255, 0, 0), (0, 0, 0), (255, 255, 255)]
        for colour in colours {
            let source = try flat(colour, width: width, height: height)
            let encoder = try VideoEncoder(width: width, height: height, preferred: .hevc, bitsPerSecond: 20_000_000)
            defer { encoder.invalidate() }
            let frames = Box<[EncodedFrame]>([])
            let encoded = expectation(description: "encoded \(colour)"); encoded.expectedFulfillmentCount = 4
            encoder.onFrame = { frames.append($0); encoded.fulfill() }
            for index in 0..<4 {
                XCTAssertTrue(encoder.encode(source, captureHostTimeNs: UInt64(index)))
                usleep(20_000)
            }
            wait(for: [encoded], timeout: 5)
            let stream = frames.value.sorted { $0.seq < $1.seq }
            let decoder = try VideoDecoder(config: try XCTUnwrap(stream.first?.videoConfig))
            defer { decoder.invalidate() }
            let decoded = Box<[DecodedFrame]>([])
            decoder.onFrame = { decoded.append($0) }
            for frame in stream { try decoder.decode(frame.videoFrame) }
            let picture = try XCTUnwrap(decoded.value.last?.pixelBuffer)

            XCTAssertEqual(CVPixelBufferGetPixelFormatType(picture), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, "video range")
            func tag(_ key: CFString) -> String? { CVBufferCopyAttachment(picture, key, nil) as? String }
            XCTAssertEqual(tag(kCVImageBufferYCbCrMatrixKey), kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
            XCTAssertEqual(tag(kCVImageBufferColorPrimariesKey), kCVImageBufferColorPrimaries_ITU_R_709_2 as String)
            XCTAssertEqual(tag(kCVImageBufferTransferFunctionKey), kCVImageBufferTransferFunction_sRGB as String)

            let pixels = drawn(picture, context: context)
            var sum = (r: 0.0, g: 0.0, b: 0.0), count = 0.0
            for y in stride(from: 8, to: height - 8, by: 4) {
                for x in stride(from: 8, to: width - 8, by: 4) {
                    let p = (y * width + x) * 4
                    sum.b += Double(pixels[p]); sum.g += Double(pixels[p + 1]); sum.r += Double(pixels[p + 2]); count += 1
                }
            }
            let shown = (r: sum.r / count, g: sum.g / count, b: sum.b / count)
            let what = "\(colour) came back as (\(shown.r), \(shown.g), \(shown.b))"
            XCTAssertEqual(shown.r, Double(colour.r), accuracy: 2, what)
            XCTAssertEqual(shown.g, Double(colour.g), accuracy: 2, what)
            XCTAssertEqual(shown.b, Double(colour.b), accuracy: 2, what)
        }
    }
}

/// A value the encoder's and decoder's callbacks fill in from their own threads.
private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var inner: Value
    init(_ value: Value) { inner = value }
    var value: Value { lock.withLock { inner } }
    func append<Element>(_ element: Element) where Value == [Element] { lock.withLock { inner.append(element) } }
}
