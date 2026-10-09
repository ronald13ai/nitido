import Foundation
import os

private let log = Logger(subsystem: "ai.ronar.nitido", category: "codec")

/// Hands codec failures that cannot be thrown (they happen on a VideoToolbox queue, or after the
/// call that caused them has returned) to the handler the caller set. Every failure is logged here.
///
/// A failure raised while no handler is set is held, the first `capacity` of them, and delivered
/// as soon as a handler is set, so a property rejected inside `init` still reaches the UI.
/// Thread-safe; the handler is never called while the lock is held.
final class FailureChannel: @unchecked Sendable {
    typealias Handler = @Sendable (CodecError) -> Void
    static let capacity = 16

    private let lock = NSLock()
    private var handler: Handler?       // guarded by `lock`
    private var held: [CodecError] = [] // guarded by `lock`

    var onError: Handler? {
        get { lock.withLock { handler } }
        set {
            let backlog: [CodecError] = lock.withLock {
                handler = newValue
                guard newValue != nil else { return [] }
                defer { held.removeAll() }
                return held
            }
            if let newValue { backlog.forEach { newValue($0) } }
        }
    }

    func report(_ error: CodecError, _ context: String) {
        log.error("\(context, privacy: .public): \(String(describing: error), privacy: .public)")
        deliver(error)
    }

    /// Hands `error` to the handler, or holds it, without logging it: for what the caller logged itself, at another
    /// level (a frame VideoToolbox dropped is not an error, `VideoEncoder`).
    func deliver(_ error: CodecError) {
        let target: Handler? = lock.withLock {
            if let handler { return handler }
            if held.count < Self.capacity { held.append(error) }
            return nil
        }
        target?(error)
    }
}
