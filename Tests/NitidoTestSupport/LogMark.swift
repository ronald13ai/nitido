import Foundation
import OSLog

/// A point in this process's log. An entry's `date` can read a few milliseconds earlier than `Date()` did when it was
/// logged, so a window that starts at a `Date()` misses what was logged right after it; one that starts at a mark,
/// in the log's own order, does not.
public struct LogMark {
    private struct NotFound: Error {}
    private let id = UUID().uuidString
    /// Where reading starts: the mark, not this date, bounds the window.
    private let readFrom = Date(timeIntervalSinceNow: -1)

    public init() {
        let id = id
        Logger(subsystem: "ai.ronar.nitido.tests", category: "mark").notice("\(id, privacy: .public)")
    }

    /// The `ai.ronar.nitido` entries in `category` logged after the mark.
    public func entries(_ category: String) throws -> [OSLogEntryLog] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let all = try store.getEntries(at: store.position(date: readFrom)).compactMap { $0 as? OSLogEntryLog }
        guard let mark = all.lastIndex(where: { $0.subsystem == "ai.ronar.nitido.tests" && $0.composedMessage == id }) else {
            throw NotFound()
        }
        return all[(mark + 1)...].filter { $0.subsystem == "ai.ronar.nitido" && $0.category == category }
    }
}

extension OSLogEntryLog {
    /// The strings Console shows as '<private>': those not logged with `privacy: .public`. Read back in this process
    /// the message can come out whole (a string from the binary is never redacted), so the check is on the format.
    public var redactedStrings: [String] {
        components.filter { $0.argumentCategory == .string && !$0.placeholder.contains("{public}") }
            .map { $0.argumentStringValue ?? "" }
    }
}
