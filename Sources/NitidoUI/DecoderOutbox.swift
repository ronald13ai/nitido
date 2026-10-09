import Foundation
import NitidoCodec

/// Carries a decoder's output from its queue to the main actor without letting pictures pile up on the way (spec 4: the
/// newest decoded frame is the one shown). Failures and superseded frames go through one by one, in decode order. Of the
/// pictures, only the newest waits: a newer one takes its place, and the one it replaces is let go at once, so its buffer
/// goes back to the decoder's pool, and is reported as `.replaced` where it was, so it counts as a dropped frame and a
/// frame decoded after a failure still comes after that failure. The first output to wait schedules one drain on the
/// main actor, which takes everything waiting however much came meanwhile: a main actor that runs late holds one
/// picture, not one per decoded frame, and its queue holds one hop, not one per frame.
///
/// One hop per decoded frame, each holding its pixel buffer, is what this replaces: the two-Mac test's viewer drew 33
/// frames a second of the 58 it decoded, so pictures waited in the main queue in growing numbers between draws.
final class DecoderOutbox: @unchecked Sendable {
    /// What a decoder hands the main actor, in decode order.
    enum Output: Sendable {
        /// The newest decoded picture.
        case frame(DecodedFrame)
        /// A decoded picture a newer one replaced before the main actor took it: it never reaches the screen.
        case replaced(seq: UInt32)
        /// A frame the decoder could not read (`VideoDecoder.onDecodeFailure`).
        case decodeFailure(seq: UInt32, error: CodecError)
        /// A frame a keyframe superseded before its turn (`VideoDecoder.onSuperseded`).
        case superseded(seq: UInt32)
    }

    private let lock = NSLock()
    // Guarded by `lock`.
    /// Outputs not drained yet, in decode order; at most one is a `.frame`, the newest, at `frameIndex`.
    private var waiting: [Output] = []
    private var frameIndex: Int?
    private var drainScheduled = false

    /// Runs the drain on the main thread, later: the main queue in the app, by hand in tests.
    private let hop: @Sendable (@escaping @Sendable () -> Void) -> Void
    private let deliver: @MainActor @Sendable (Output) -> Void

    /// `deliver` gets every output on the main actor, in decode order.
    init(hop: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
         deliver: @escaping @MainActor @Sendable (Output) -> Void) {
        self.hop = hop
        self.deliver = deliver
    }

    /// Takes `decoder`'s pictures, failures and superseded frames from now on.
    func attach(to decoder: VideoDecoder) {
        decoder.onFrame = { [self] frame in post(.frame(frame)) }
        decoder.onDecodeFailure = { [self] seq, error in post(.decodeFailure(seq: seq, error: error)) }
        decoder.onSuperseded = { [self] seq in post(.superseded(seq: seq)) }
    }

    /// From the decoder's queue (any thread): queues `output` for the next drain, a picture in place of the one waiting.
    func post(_ output: Output) {
        let scheduleDrain: Bool = lock.withLock {
            if case .frame = output {
                if let index = frameIndex, case .frame(let older) = waiting[index] {
                    waiting[index] = .replaced(seq: older.seq)   // its buffer is let go here
                }
                frameIndex = waiting.count
            }
            waiting.append(output)
            defer { drainScheduled = true }
            return !drainScheduled
        }
        if scheduleDrain {
            hop { [self] in MainActor.assumeIsolated { drain() } }
        }
    }

    /// Hands everything waiting to `deliver`, in order. The next output schedules the next drain.
    @MainActor
    private func drain() {
        let outputs: [Output] = lock.withLock {
            defer { waiting = []; frameIndex = nil; drainScheduled = false }
            return waiting
        }
        outputs.forEach(deliver)
    }
}
