import SwiftUI
import AppKit
import os

private let log = Logger(subsystem: "ai.ronar.nitido", category: "app")

@MainActor @Observable
public final class AppModel {
    public enum Screen: Equatable { case welcome, share, view }
    public var screen: Screen = .welcome
    public private(set) var share: ShareModel?
    public private(set) var view: ViewModel?
    /// Raises "Stop sharing?" or "Disconnect?" (`RootView`) before a live session ends.
    public var confirmStop = false
    /// The question on screen was asked by a quit (`requestQuit`): Stop quits once the session has stopped.
    @ObservationIgnored private var quitAsked = false
    /// Makes the share and the viewer, and quits the app; tests give their own.
    @ObservationIgnored private let makeShare: @MainActor () -> ShareModel
    @ObservationIgnored private let makeView: @MainActor () -> ViewModel
    @ObservationIgnored private let terminate: @MainActor () -> Void

    public convenience init() {
        self.init(makeShare: { ShareModel() }, makeView: { ViewModel() }, terminate: { NSApplication.shared.terminate(nil) })
    }

    init(makeShare: @escaping @MainActor () -> ShareModel, makeView: @escaping @MainActor () -> ViewModel,
         terminate: @escaping @MainActor () -> Void) {
        self.makeShare = makeShare; self.makeView = makeView; self.terminate = terminate
    }

    /// Shows the Share screen and the picker. One share at a time: while a share is picking or capturing this
    /// does nothing more; after a failure it reuses the same model, which stops its old session first. A cancelled
    /// picker goes back to Welcome, or to the View screen while a viewer is open (`cancelShare`), and lets the model go.
    public func startShare() {
        let excluded = NSApplication.shared.windows.filter { $0.windowNumber > 0 }.map { CGWindowID($0.windowNumber) }
        screen = .share
        if let share {
            share.start(excludingWindowIDs: excluded)
            return
        }
        let model = makeShare()
        share = model
        // A cancelled picker drops the share alone instead of leaving an empty Share screen.
        model.onCancelled = { [weak self, weak model] in
            guard let self, let model, share === model else { return }
            cancelShare()
        }
        model.start(excludingWindowIDs: excluded)
    }

    /// The share's picker was cancelled before anything was shared (its first pick, or the one after Retry): only the
    /// share goes. The window goes back where the person came from: the View screen while a viewer is open (on the Share
    /// screen a viewer can only be there because they came from View with ⌘N, since `stop` always lets the viewer go),
    /// Welcome otherwise. A viewer's link stays as it was, connected or not.
    func cancelShare() {
        let s = share
        share = nil
        screen = view != nil ? .view : .welcome
        Task { await s?.stop() }
    }

    /// Shows the View screen. One viewer at a time: a viewer that exists already (browsing, connected or failed) is
    /// kept, so ⌘⇧V twice never leaves a replaced viewer's link open with nobody to close it.
    public func startView() {
        if view == nil { view = makeView() }
        screen = .view
    }

    /// ⌘H, ⌘Z, ⌘⌫ and ⌘L act on the screen shown, never on a share running behind the View screen.
    public func toggleTelemetry() {
        switch screen {
        case .share: share?.showTelemetry.toggle()
        case .view: view?.showTelemetry.toggle()
        case .welcome: break
        }
    }

    public func toggleLoopback() {
        guard menu.canToggleLoop else { return }
        share?.loopback.toggle()
    }

    public func undo() {
        switch screen {
        case .share: share?.ink.undoLocal()
        case .view: view?.ink.undoLocal()
        case .welcome: break
        }
    }

    public func clearInk() {
        switch screen {
        case .share: share?.ink.clearLocal()
        case .view: view?.ink.clearLocal()
        case .welcome: break
        }
    }

    /// What the menu offers on the screen shown: an item that would do nothing there is disabled, and the Esc item
    /// says what it stops.
    public struct Menu: Equatable, Sendable {
        public var stopTitle: String
        public var canStop: Bool
        public var canToggleTelemetry: Bool
        public var canInk: Bool
        public var canToggleLoop: Bool
    }

    public var menu: Menu { Self.menu(screen: screen, sharing: sharing, viewing: viewing, viewBack: viewBack) }

    /// `sharing`: a picture is being shared; `viewing`: a viewer is connected or reconnecting; `viewBack`: the View
    /// screen shows the code or a failure, where Esc does what Back does (`requestStop`). Esc on Welcome does
    /// nothing; the ink is there only over a live picture; the codec loop belongs to a live share.
    nonisolated static func menu(screen: Screen, sharing: Bool, viewing: Bool, viewBack: Bool = false) -> Menu {
        let stopTitle: String = switch (sharing, viewing, screen) {
        case (_, _, .view) where viewBack: "Back"
        case (true, true, _): "Stop Sharing and Disconnect"
        case (true, false, _): "Stop Sharing"
        case (false, true, _): "Disconnect"
        case (false, false, .share): "Stop Sharing"
        case (false, false, .view): "Back"
        case (false, false, .welcome): "Stop"
        }
        return Menu(stopTitle: stopTitle, canStop: screen != .welcome, canToggleTelemetry: screen != .welcome,
                    canInk: screen == .share ? sharing : screen == .view ? viewing : false,
                    canToggleLoop: screen == .share && sharing)
    }

    /// Detach before the await (Task 8 fix): a Share or View that lands while the old one is still stopping
    /// keeps its own model instead of being cleared when this stop resumes. Returns once the other Mac has been told
    /// `bye` (or its link gave up), so a quit (`shouldQuitNow`) does not cut the goodbye off.
    public func stop() async {
        let s = share, v = view
        share = nil; view = nil
        screen = .welcome
        // Both goodbyes at once: one after the other, a slow viewer's bye (up to its link's one-second fallback) could
        // push the share's past the quit's two-second deadline, and its viewer would read a dropped link and reconnect.
        async let viewerDone: Void? = v?.disconnectAndWait()
        async let shareDone: Void? = s?.stop()
        _ = await (viewerDone, shareDone)
    }

    /// A quit the person asked for: ⌘Q, ⌘W or the window's close button (the app quits with its only window,
    /// `AppDelegate`). While a picture is shared or a viewer is connected or reconnecting it asks first, the same
    /// question as Esc, and quits only once they choose Stop and the session has stopped (`confirmedStop`); otherwise
    /// it quits at once. One stray ⌘W, next to ⌘Q, no longer ends a pairing session for both Macs.
    public func requestQuit() {
        guard sharing || viewing else { terminate(); return }
        quitAsked = true
        confirmStop = true
    }

    /// The question's destructive button: stops what is live, then quits if a quit asked the question, once the other
    /// Mac has been told `bye`, or after `quitDeadline` at most.
    public func confirmedStop() {
        guard quitAsked else { Task { await stop() }; return }
        quitAsked = false
        let once = Once(terminate)
        Task {
            await stop()
            once.run()
        }
        let deadline = quitDeadline
        Task {
            try? await Task.sleep(for: deadline)   // never cancelled; a stop that finished first has quit already
            if once.pending { log.error("The session did not stop within \(deadline, privacy: .public); quitting anyway") }
            once.run()
        }
    }

    /// The longest a quit waits for the session to stop (`confirmedStop`, `shouldQuitNow`).
    @ObservationIgnored var quitDeadline: Duration = .seconds(2)

    /// The question's Cancel (or Esc on it): nothing stops, and a quit that asked it does not happen.
    public func cancelledStop() { quitAsked = false }

    /// The system's own quit (a logout, a restart, Quit in the Dock), which asks nothing: with nothing live this answers
    /// true, quit now. With a share or a viewer it answers false, stops them first so the other Mac is told `bye` instead
    /// of seeing a dropped link it would keep reconnecting to, and calls `quit` once that is done, or after `deadline` at
    /// most. ⌘Q, ⌘W and the close button ask first instead (`requestQuit`), and reach this with nothing live.
    public func shouldQuitNow(deadline: Duration = .seconds(2), then quit: @escaping @MainActor () -> Void) -> Bool {
        guard share != nil || view != nil else { return true }
        log.info("Quitting: stopping the live session first")
        let once = Once(quit)
        Task {
            await stop()
            once.run()
        }
        Task {
            try? await Task.sleep(for: deadline)   // never cancelled; a stop that finished first has quit already
            if once.pending { log.error("The session did not stop within \(deadline, privacy: .public); quitting anyway") }
            once.run()
        }
        return false
    }

    private var sharing: Bool { share?.state == .capturing }
    private var viewing: Bool {
        view.map { if case .connected = $0.state { return true }; if case .reconnecting = $0.state { return true }; return false } ?? false
    }

    /// The confirmation's title and destructive button (`RootView`): what Esc stops. A share keeps running behind the
    /// View screen (`startView`), and the same confirmation stops it, so the question names both.
    nonisolated static func stopWording(sharing: Bool, viewing: Bool) -> (question: String, action: String) {
        switch (sharing, viewing) {
        case (true, true): ("Stop sharing and disconnect?", "Stop and Disconnect")
        case (true, false): ("Stop sharing?", "Stop")
        default: ("Disconnect?", "Disconnect")
        }
    }
    public var stopQuestion: String { Self.stopWording(sharing: sharing, viewing: viewing).question }
    public var stopAction: String { Self.stopWording(sharing: sharing, viewing: viewing).action }

    /// The confirmation's message: who is disconnected, and what they will see. `viewer` is the share's viewer, if one is
    /// connected; `sharer` the Mac this one is viewing.
    nonisolated static func stopMessage(sharing: Bool, viewing: Bool, viewer: String?, sharer: String) -> String {
        switch (sharing, viewing) {
        case (true, true):
            let first = viewer.map { "\($0) will see that you stopped sharing" } ?? "Your share stops"
            return "\(first), and \(sharer.isEmpty ? "the other Mac" : sharer) will see that you disconnected."
        case (true, false):
            return viewer.map { "\($0) will see that you stopped sharing." } ?? "The picture closes and the code stops working."
        default:
            return "\(sharer.isEmpty ? "The other Mac" : sharer) will see that you disconnected."
        }
    }
    public var stopMessage: String {
        Self.stopMessage(sharing: sharing, viewing: viewing, viewer: share?.viewerName, sharer: view?.sharerName ?? "")
    }

    /// The View screen shows the code (entering it or connecting with it) or a failure: Esc there does what its Back
    /// button does, back to the list, instead of leaving View (or asking about a share running behind it).
    private var viewBack: Bool {
        guard screen == .view, let view else { return false }
        switch view.state {
        case .enteringCode, .connecting, .failed: return true
        case .browsing, .connected, .reconnecting: return false
        }
    }

    /// On the code or a failure of the View screen, Esc is Back: to the list of Macs (`viewBack`). Otherwise it asks
    /// first (`stopQuestion`, `RootView`) while a picture is being shared or a viewer is connected or reconnecting; with
    /// nothing live (a picker, the list of Macs) it stops at once.
    public func requestStop() {
        if viewBack, let view { view.disconnect(); return }
        quitAsked = false
        if sharing || viewing { confirmStop = true } else { Task { await stop() } }
    }

    /// The one entry point for Esc: the invisible in-window button on the Share and View screens and the Stop
    /// menu item both call it, so Esc asks first whether or not the window is key. Never `stop()` from an Esc path.
    public func escape() { requestStop() }
}

public struct RootView: View {
    @Bindable var app: AppModel
    public init(app: AppModel) { self.app = app }
    /// Screens come in with the entrance (opacity and scale 0.98) and go faster, opacity only (`screenTransition`).
    public var body: some View {
        ZStack {
            switch app.screen {
            case .welcome:
                WelcomeView(onShare: { app.startShare() }, onView: { app.startView() }).screenTransition()
            case .share:
                if let share = app.share {
                    ShareView(model: share).background(EscapeStops { app.escape() }).screenTransition()
                }
            case .view:
                if let view = app.view { ViewView(model: view).background(EscapeStops { app.escape() }).screenTransition() }
            }
        }
        .animation(Theme.Motion.enter, value: app.screen)
        .background(KeepWindowOnScreen())
        // The close button (and ⌘W, which presses it) asks first while something is live, as ⌘Q does.
        .background(CloseButtonQuits { app.requestQuit() })
        // Raised by `requestStop` (Esc, the Stop menu item) while something is live; it names what stops, and who
        // will see it.
        .confirmationDialog(app.stopQuestion, isPresented: $app.confirmStop) {
            Button(app.stopAction, role: .destructive) { app.confirmedStop() }
            Button("Cancel", role: .cancel) { app.cancelledStop() }
        } message: {
            Text(app.stopMessage)
        }
    }
}

/// Runs an action once, whichever of two paths gets there first (`AppModel.shouldQuitNow`).
@MainActor
private final class Once {
    private var action: (@MainActor () -> Void)?
    init(_ action: @escaping @MainActor () -> Void) { self.action = action }
    var pending: Bool { action != nil }
    func run() { let a = action; action = nil; a?() }
}

/// Esc inside the window. A menu item's Esc shortcut never fires while a window is key, so the Share and
/// View screens carry this invisible button; Welcome does not, so Esc there does nothing. It must call
/// `app.escape()`, never `app.stop()` directly, so the confirmation (`requestStop`) also covers it.
private struct EscapeStops: View {
    let action: () -> Void
    var body: some View {
        Button("Stop", action: action)
            .keyboardShortcut(.cancelAction)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }
}

/// The window's close button, and ⌘W (File, Close presses it), quit through `AppModel.requestQuit`, which asks first
/// while something is live. Closing the only window quits the app anyway (`AppDelegate`); closed directly, the window
/// would be gone before the question, and a Cancel would leave the session running with no window.
struct CloseButtonQuits: NSViewRepresentable {
    let action: @MainActor () -> Void
    func makeNSView(context: Context) -> CloseButtonQuitsView { CloseButtonQuitsView(action: action) }
    func updateNSView(_ view: CloseButtonQuitsView, context: Context) { view.action = action; view.retarget() }
}

final class CloseButtonQuitsView: NSView {
    var action: @MainActor () -> Void
    init(action: @escaping @MainActor () -> Void) { self.action = action; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        if let window {
            // Again whenever the window becomes key, should anything have pointed the button elsewhere meanwhile.
            NotificationCenter.default.addObserver(self, selector: #selector(windowBecameKey(_:)),
                                                   name: NSWindow.didBecomeKeyNotification, object: window)
        }
        retarget()
    }

    @objc private func windowBecameKey(_ note: Notification) { retarget() }

    /// Points the window's close button at `closeClicked`. Internal so a test can check it on a window of its own.
    func retarget() {
        guard let button = window?.standardWindowButton(.closeButton) else { return }
        if button.target !== self { button.target = self }
        if button.action != #selector(closeClicked(_:)) { button.action = #selector(closeClicked(_:)) }
    }

    @objc func closeClicked(_ sender: Any?) { action() }
}
