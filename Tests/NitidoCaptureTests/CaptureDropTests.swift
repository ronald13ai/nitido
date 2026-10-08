import XCTest
import CoreVideo
@testable import NitidoCapture

/// Spec 10 and 12: the strip shows dropped frames, and a frame the capture stream let go because the share had not
/// taken the one before it yet (the stream keeps only the newest) is one.
final class CaptureDropTests: XCTestCase {
    private func frame() throws -> CapturedFrame {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, 8, 6, kCVPixelFormatType_32BGRA, nil, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw XCTSkip("CVPixelBufferCreate failed: \(status)") }
        return CapturedFrame(pixelBuffer: buffer, captureHostTimeNs: 1, contentRect: CGRect(x: 0, y: 0, width: 4, height: 3), scale: 2)
    }

    @MainActor
    func testAFrameReplacedBeforeTheShareTookItCountsAsDropped() throws {
        let session = CaptureSession()
        XCTAssertEqual(session.takeDroppedFrames(), 0)
        session.deliverForTesting(try frame())   // waits for the share
        session.deliverForTesting(try frame())   // replaces it: the first is dropped
        XCTAssertEqual(session.takeDroppedFrames(), 1)
        XCTAssertEqual(session.takeDroppedFrames(), 0, "each drop is taken once")
    }
}
