import Foundation
import os

private let log = Logger(subsystem: "ai.ronar.nitido", category: "activity")

/// Holds off idle display sleep and idle system sleep, and App Nap with them, while a session is live: a viewer watches
/// without touching the keyboard or the trackpad, and the person sharing often only watches the other side's ink. Left
/// to the idle timers (a few minutes on battery), the display dims, goes black and locks mid-session, an idle Mac
/// sleeps and drops the link, and a napped app's timers (the link's 3 s pong check among them) are deferred. One
/// `ProcessInfo` activity at a time: `begin` while one is held does nothing, so a reconnect or a re-pick never stacks
/// them, and `end` lets it go once. `pmset -g assertions` lists it under the reason given, while it is held.
final class SessionActivity {
    /// What the activity asks of the system: a user-initiated task (no idle system sleep, no App Nap) that keeps the
    /// display on. Not latency-critical: nothing measured needs the timer precision that costs power.
    static let options: ProcessInfo.ActivityOptions = [.userInitiated, .idleDisplaySleepDisabled]

    private var token: NSObjectProtocol?
    private let beginActivity: (String) -> NSObjectProtocol
    private let endActivity: (NSObjectProtocol) -> Void
    /// Activities begun so far, for tests.
    private(set) var begun = 0

    init(begin: @escaping (String) -> NSObjectProtocol = { ProcessInfo.processInfo.beginActivity(options: SessionActivity.options, reason: $0) },
         end: @escaping (NSObjectProtocol) -> Void = { ProcessInfo.processInfo.endActivity($0) }) {
        beginActivity = begin; endActivity = end
    }

    var isHeld: Bool { token != nil }

    func begin(_ reason: String) {
        guard token == nil else { return }
        token = beginActivity(reason); begun += 1
        log.info("holding off display and idle sleep: \(reason, privacy: .public)")
    }

    func end() {
        guard let token else { return }
        self.token = nil
        endActivity(token)
        log.info("display and idle sleep allowed again")
    }

    deinit { if let token { endActivity(token) } }
}
