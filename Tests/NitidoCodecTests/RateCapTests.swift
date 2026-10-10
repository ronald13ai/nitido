import XCTest
import CoreVideo
import CoreText
import QuartzCore
@testable import NitidoCodec
@testable import NitidoCore

/// The encoder's hard cap on bytes (`DataRateLimits`, spec 7) against the hardest content short of noise: a page of dense
/// text scrolled six pixels a frame, every frame different all over, at 60 fps and a low rate.
final class RateCapTests: XCTestCase {
    /// The soak test of 2026-10-10: with the cap at 1.5 times the average per second, VideoToolbox dropped five frames
    /// in a row some ten frames after a periodic keyframe, 83 ms frozen every 2 s, at 2400 × 1560 and 4 or 8 Mbps. Here,
    /// in two runs before the fix: frames 249 to 253 at 8 Mbps both times, and at 4 Mbps two bursts of five, from frame
    /// 143 or 145 and from 270 or 273. Over five seconds, two periodic keyframes, the encoder emits every frame it takes.
    func testADenseScrollingPageAtALowRateLosesNoFrameAfterThePeriodicKeyframes() throws {
        let page = try TextPage(width: 2400, height: 1560)
        for mbps in [8, 4] {
            let run = try encode(page, bitsPerSecond: mbps * 1_000_000, frames: 300)
            XCTAssertEqual(run.failures, [], "\(mbps) Mbps: no encoder failure")
            XCTAssertEqual(run.dropped, [], "\(mbps) Mbps: VideoToolbox dropped frames \(run.dropped)")
            XCTAssertEqual(run.keyframes, [0, 120, 240], "\(mbps) Mbps: the periodic keyframes")
        }
    }

    private struct Run {
        /// The sequence numbers of the frames the encoder took and VideoToolbox dropped.
        var dropped: [UInt32]
        var keyframes: [UInt32]
        var failures: [CodecError]
    }

    /// Hands a HEVC encoder `frames` frames of `page`, one every 1/60 s on the wall clock as the capture does, each
    /// scrolled six pixels further, and waits for every one it took to come out or be dropped. A frame it turns away
    /// with two in flight (the first few, while the session warms up) is not one VideoToolbox dropped.
    private func encode(_ page: TextPage, bitsPerSecond: Int, frames: Int) throws -> Run {
        let encoder = try VideoEncoder(width: page.width, height: page.height, preferred: .hevc, bitsPerSecond: bitsPerSecond)
        defer { encoder.invalidate() }
        let emitted = Box<[(seq: UInt32, isKey: Bool)]>([]), drops = Box<[Bool]>([]), failures = Box<[CodecError]>([])
        encoder.onFrame = { emitted.append(($0.seq, $0.isKey)) }
        encoder.onError = { error in
            if error == .frameDropped { drops.append(true) } else { failures.append(error) }
        }
        let start = CACurrentMediaTime()
        var taken = 0
        for index in 0..<frames {
            let due = start + Double(index) / 60
            let wait = due - CACurrentMediaTime()
            if wait > 0 { usleep(UInt32(wait * 1_000_000)) }
            let buffer = try page.frame(index: index)
            if encoder.encode(buffer, captureHostTimeNs: UInt64(due * 1e9)) { taken += 1 }
        }
        let deadline = CACurrentMediaTime() + 5
        while emitted.value.count + drops.value.count + failures.value.count < taken, CACurrentMediaTime() < deadline {
            usleep(10_000)
        }
        let seen = Set(emitted.value.map(\.seq))
        return Run(dropped: (0..<UInt32(taken)).filter { !seen.contains($0) },
                   keyframes: emitted.value.filter(\.isKey).map(\.seq).sorted(),
                   failures: failures.value)
    }
}

/// A long page of text drawn once, which frame `index` shows scrolled `6 × index` pixels down: Menlo 13 on cream in three
/// inks, a gold band every 23 lines, lines of 40 to 340 characters. Frames come from one pool, as the capture's do.
private final class TextPage {
    let width: Int
    let height: Int
    private let travel = 2400
    private let rowBytes: Int
    private let pattern: UnsafeMutableRawPointer
    private let pool: CVPixelBufferPool

    init(width: Int, height: Int) throws {
        self.width = width; self.height = height
        rowBytes = width * 4
        let rows = height + travel
        pattern = .allocate(byteCount: rowBytes * rows, alignment: 64)
        guard let context = CGContext(data: pattern, width: width, height: rows, bitsPerComponent: 8, bytesPerRow: rowBytes,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { pattern.deallocate(); throw XCTSkip("no CGContext over the page") }
        context.setFillColor(CGColor(red: 0.98, green: 0.97, blue: 0.94, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: rows))
        let font = CTFontCreateWithName("Menlo" as CFString, 13, nil)
        let words = ["let", "frame", "encoder", "decoder", "viewer", "keyframe", "backlog", "0x6a", "return", "guard",
                     "await", "Nitido", "{", "}", "(", ")", "=", "+", "1756", "2692", "sharer", "divider", "pacer"]
        let inks = [CGColor(red: 0.08, green: 0.07, blue: 0.06, alpha: 1), CGColor(red: 0.55, green: 0.35, blue: 0.05, alpha: 1),
                    CGColor(red: 0.10, green: 0.30, blue: 0.55, alpha: 1)]
        var line = 0
        for y in stride(from: 6, to: rows, by: 17) {
            if line % 23 == 0 {
                context.setFillColor(CGColor(red: 0.85, green: 0.78, blue: 0.55, alpha: 1))
                context.fill(CGRect(x: 0, y: y - 4, width: width, height: 17))
            }
            var text = "\(line)  ", i = line
            while text.count < 40 + (line * 37) % 300 { text += words[(i * 7 + line) % words.count] + " "; i += 1 }
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): inks[line % inks.count],
            ]
            context.textPosition = CGPoint(x: 10, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
            line += 1
        }
        let attributes: [CFString: Any] = [
            kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary, kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var made: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary, attributes as CFDictionary, &made)
        guard let made else { pattern.deallocate(); throw XCTSkip("no pixel buffer pool") }
        pool = made
    }

    deinit { pattern.deallocate() }

    func frame(index: Int) throws -> CVPixelBuffer {
        var made: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made), kCVReturnSuccess)
        let buffer = try XCTUnwrap(made)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let offset = (index * 6) % travel
        for y in 0..<height { memcpy(base + y * stride, pattern + (offset + y) * rowBytes, rowBytes) }
        return buffer
    }
}
