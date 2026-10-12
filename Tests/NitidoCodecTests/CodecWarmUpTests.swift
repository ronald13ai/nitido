import XCTest
import QuartzCore
@testable import NitidoCodec

/// VideoToolbox's first session in a process is slow to make; the warm-up makes one off the main thread, so the share's
/// first encoder and the viewer's first decoder, made on the main actor, are not.
final class CodecWarmUpTests: XCTestCase {
    /// The warm-up runs to its end (an encoder, one frame, a decoder for it, all let go), and an encoder made after it
    /// comes quickly.
    func testTheWarmUpLeavesTheNextEncoderQuick() throws {
        CodecWarmUp.warm()
        let start = CACurrentMediaTime()
        let encoder = try VideoEncoder(width: 1280, height: 800, bitsPerSecond: 8_000_000)
        let made = CACurrentMediaTime() - start
        encoder.invalidate()
        XCTAssertLessThan(made, 0.05, "an encoder after the warm-up took \(Int(made * 1000)) ms")
    }

    /// `start` warms once per process, however often it is called. The first call may have come from a model another
    /// test made (the suite is one process), so only the calls after it are asserted.
    func testStartIsOncePerProcess() {
        CodecWarmUp.start()
        XCTAssertFalse(CodecWarmUp.start(), "called again, it starts nothing")
        XCTAssertFalse(CodecWarmUp.start())
    }
}
