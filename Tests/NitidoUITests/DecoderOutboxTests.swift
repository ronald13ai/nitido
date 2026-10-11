import XCTest
import CoreVideo
@testable import NitidoCodec
@testable import NitidoUI

/// Makes small pixel buffers and counts the ones still alive: each tells it when it is freed.
private final class LiveBuffers: @unchecked Sendable {
    private let lock = NSLock()
    private var live = 0
    var count: Int { lock.withLock { live } }

    func make() -> CVPixelBuffer {
        let bytesPerRow = 8 * 4
        let memory = UnsafeMutableRawPointer.allocate(byteCount: bytesPerRow * 6, alignment: 16)
        let refcon = Unmanaged.passRetained(self).toOpaque()
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreateWithBytes(nil, 8, 6, kCVPixelFormatType_32BGRA, memory, bytesPerRow, { refcon, base in
            base.map { UnsafeMutableRawPointer(mutating: $0).deallocate() }
            guard let refcon else { return }
            Unmanaged<LiveBuffers>.fromOpaque(refcon).takeRetainedValue().freed()
        }, refcon, nil, &buffer)
        precondition(status == kCVReturnSuccess, "CVPixelBufferCreateWithBytes failed: \(status)")
        lock.withLock { live += 1 }
        return buffer!
    }

    private func freed() { lock.withLock { live -= 1 } }
}

/// The drains an outbox schedules, run by hand on the main thread, as a main thread that is late to run them would.
private final class Hops: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [@Sendable () -> Void] = []
    var count: Int { lock.withLock { pending.count } }
    func add(_ hop: @escaping @Sendable () -> Void) { lock.withLock { pending.append(hop) } }
    func runAll() {
        let due = lock.withLock { defer { pending = [] }; return pending }
        due.forEach { $0() }
    }
}

/// What the outbox handed the main actor, in order.
@MainActor
private final class Delivered {
    var outputs: [DecoderOutbox.Output] = []
    var lines: [String] {
        outputs.map {
            switch $0 {
            case .frame(let f): "frame \(f.seq)"
            case .replaced(let seq): "replaced \(seq)"
            case .decodeFailure(let seq, _): "failure \(seq)"
            case .superseded(let seq): "superseded \(seq)"
            }
        }
    }
}

final class DecoderOutboxTests: XCTestCase {
    /// A main thread that runs late (the two-Mac test's viewer showed 33 of 58 frames a second) finds one picture
    /// waiting for it, the newest, not one per decoded frame: each picture a newer one replaces is let go at once, its
    /// buffer back to the decoder's pool, and reported in its place as `.replaced`, so it counts as dropped. Failures and
    /// superseded frames keep their order around the pictures, so a frame decoded after a failure still resets the
    /// failure count after it. One drain is scheduled for all of it, and a later output schedules the next.
    @MainActor
    func testOnlyTheNewestPictureWaitsForTheMainThreadAndTheRestKeepsItsOrder() throws {
        let buffers = LiveBuffers()
        let hops = Hops()
        let delivered = Delivered()
        let outbox = DecoderOutbox(hop: { hops.add($0) }, deliver: { delivered.outputs.append($0) })
        func picture(_ seq: UInt32) -> DecoderOutbox.Output {
            .frame(DecodedFrame(pixelBuffer: buffers.make(), captureHostTimeNs: UInt64(seq), seq: seq, width: 8, height: 6))
        }
        let decoderQueue = DispatchQueue(label: "test.decoder")
        decoderQueue.sync {
            for seq in UInt32(0)..<10 { outbox.post(picture(seq)) }
            outbox.post(.decodeFailure(seq: 10, error: .decode(-12909)))
            for seq in UInt32(11)..<58 { outbox.post(picture(seq)) }
            outbox.post(.superseded(seq: 58))
        }
        XCTAssertEqual(hops.count, 1, "one drain for every output that waits")
        XCTAssertEqual(buffers.count, 1, "of 57 pictures decoded, only the newest is alive")

        hops.runAll()
        let replacedBefore = (0..<10).map { "replaced \($0)" }, replacedAfter = (11..<57).map { "replaced \($0)" }
        XCTAssertEqual(delivered.lines, replacedBefore + ["failure 10"] + replacedAfter + ["frame 57", "superseded 58"])
        delivered.outputs = []
        XCTAssertEqual(buffers.count, 0, "the shown picture is the main actor's to keep or let go")

        decoderQueue.sync { outbox.post(picture(59)) }
        XCTAssertEqual(hops.count, 1, "the next output schedules the next drain")
        hops.runAll()
        XCTAssertEqual(delivered.lines, ["frame 59"])
    }
}
