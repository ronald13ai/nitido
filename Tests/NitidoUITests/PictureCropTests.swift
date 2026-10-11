import XCTest
import CoreImage
import CoreVideo
@testable import NitidoUI

/// What `VideoView` draws before fitting it to the drawable (`VideoView.picture(of:)`): a decoded picture of an odd size
/// cut back to its size, and the codec loop's comparison kept inside the picture wherever the divider is.
final class PictureCropTests: XCTestCase {
    /// A BGRA buffer whose column `x` has the grey level `shade(x)`.
    private func buffer(width: Int, height: Int, shade: (Int) -> UInt8) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:]]
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let pb else { throw XCTSkip("CVPixelBufferCreate failed") }
        CVPixelBufferLockBaseAddress(pb, [])
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        for y in 0..<height {
            for x in 0..<width { let v = shade(x); let p = base + y * stride + x * 4; p[0] = v; p[1] = v; p[2] = v; p[3] = 255 }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }

    /// `image`'s pixels, its extent drawn into 8-bit sRGB BGRA, top row first.
    private func pixels(_ image: CIImage) -> [UInt8] {
        let width = Int(image.extent.width), height = Int(image.extent.height)
        var out = [UInt8](repeating: 0, count: width * height * 4)
        CIContext(options: [.workingColorSpace: VideoView.colorSpace])
            .render(image, toBitmap: &out, rowBytes: width * 4, bounds: image.extent, format: .BGRA8, colorSpace: VideoView.colorSpace)
        return out
    }

    /// A decoded 1002 × 802 buffer of a 1001 × 801 picture: the picture is its top left 1001 × 801, at the origin, and
    /// the column and row the encoder added never show.
    func testAPaddedBufferIsCutBackToThePicture() throws {
        let padded = try buffer(width: 1002, height: 802) { $0 == 1001 ? 255 : 40 }
        let picture = VideoView.picture(of: FramePacer.Frame(pixelBuffer: padded, captureHostTimeNs: 0,
                                                              pictureSize: CGSize(width: 1001, height: 801)))
        XCTAssertEqual(picture.extent, CGRect(x: 0, y: 0, width: 1001, height: 801))
        let drawn = pixels(picture)
        XCTAssertFalse(stride(from: 0, to: drawn.count, by: 4).contains { drawn[$0] > 200 }, "the added column is not part of the picture")
        let whole = VideoView.picture(of: FramePacer.Frame(pixelBuffer: padded, captureHostTimeNs: 0))
        XCTAssertEqual(whole.extent.size, CGSize(width: 1002, height: 802), "no picture size: the whole buffer")
    }

    /// The divider dragged to either edge: the comparison stays the picture's size at the origin, so the centring that
    /// follows moves nothing, the gold line stays inside the picture, and the last column is the picture's own.
    func testTheComparisonStaysInsideThePictureAtEitherEdge() throws {
        let decoded = try buffer(width: 64, height: 8) { _ in 200 }
        let raw = try buffer(width: 64, height: 8) { _ in 60 }
        for divider in [0.0, 1.0, 0.5] {
            let picture = VideoView.picture(of: FramePacer.Frame(pixelBuffer: decoded, captureHostTimeNs: 0, compareWith: raw,
                                                                  divider: divider))
            XCTAssertEqual(picture.extent, CGRect(x: 0, y: 0, width: 64, height: 8), "divider at \(divider)")
            let drawn = pixels(picture)
            let lastColumn = Array(drawn[(63 * 4)..<(64 * 4)])
            let firstColumn = Array(drawn[0..<4])
            switch divider {
            case 0: XCTAssertNotEqual(lastColumn[0], 0, "the right edge is the decoded picture, not background")
            case 1: XCTAssertNotEqual(firstColumn[0], 0, "the left edge is the raw picture")
            default: break
            }
        }
    }
}
