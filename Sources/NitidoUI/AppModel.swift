import SwiftUI
import AppKit

@MainActor @Observable
public final class AppModel {
    public enum Screen: Equatable { case welcome, share, view }
    public var screen: Screen = .welcome
    public private(set) var share: ShareModel?
    public private(set) var view: ViewModel?
    /// Raises "Stop sharing?" or "Disconnect?" (`RootView`) before a live session ends.
    public var confirmStop = false
    public init() {}

    /// Shows the Share screen and the picker. One share at a time: while a share is picking or capturing this
    /// does nothing more; after a failure it reuses the same model, which stops its old session first. A cancelled
    /// picker goes back to Welcome (`onCancelled`), which lets the model go.
    public func startShare() {
        let excluded = NSApp.windows.filter { $0.windowNumber > 0 }.map { CGWindowID($0.windowNumber) }
        screen = .share
        if let share {
            share.start(excludingWindowIDs: excluded)
            return
        }
        let model = ShareModel()
        share = model
        // A cancelled picker goes back to Welcome instead of leaving an empty Share screen.
        model.onCancelled = { [weak self] in Task { await self?.stop() } }
        model.start(excludingWindowIDs: excluded)
    }

    /// Shows the View screen. One viewer at a time: a viewer that exists already (browsing, connected or failed) is
    /// kept, so ⌘⇧V twice never leaves a replaced viewer's link open with nobody to close it.
    public func startView() {
        if view == nil { view = ViewModel() }
        screen = .view
    }

    public func toggleTelemetry() { share?.showTelemetry.toggle(); view?.showTelemetry.toggle() }

    public func toggleLoopback() { share?.loopback.toggle() }

    public func undo() { share?.ink.undoLocal(); view?.ink.undoLocal() }

    public func clearInk() { share?.ink.clearLocal(); view?.ink.clearLocal() }

    /// Detach before the await (Task 8 fix): a Share or View that lands while the old one is still stopping
    /// keeps its own model instead of being cleared when this stop resumes.
    public func stop() async {
        let s = share, v = view
        share = nil; view = nil
        screen = .welcome
        v?.disconnect()
        await s?.stop()
    }

    /// Asks first ("Stop sharing?" or "Disconnect?", `RootView`) while a picture is being shared or a viewer is
    /// connected or reconnecting; with nothing live (a picker, a list of Macs, a failure) it stops at once.
    public func requestStop() {
        let active = (share?.state == .capturing) || (view.map { if case .connected = $0.state { return true }; if case .reconnecting = $0.state { return true }; return false } ?? false)
        if active { confirmStop = true } else { Task { await stop() } }
    }

    /// The one entry point for Esc: the invisible in-window button on the Share and View screens and the Stop
    /// menu item both call it, so Esc asks first whether or not the window is key. Never `stop()` from an Esc path.
    public func escape() { requestStop() }
}

public struct RootView: View {
    @Bindable var app: AppModel
    public init(app: AppModel) { self.app = app }
    public var body: some View {
        Group {
            switch app.screen {
            case .welcome: WelcomeView(onShare: { app.startShare() }, onView: { app.startView() })
            case .share:
                if let share = app.share {
                    ShareView(model: share).background(EscapeStops { app.escape() })
                }
            case .view:
                if let view = app.view { ViewView(model: view).background(EscapeStops { app.escape() }) }
            }
        }
        .background(KeepWindowOnScreen())
        // Raised by `requestStop` (Esc, the Stop menu item) while something is live.
        .confirmationDialog(app.screen == .view ? "Disconnect?" : "Stop sharing?", isPresented: $app.confirmStop) {
            Button(app.screen == .view ? "Disconnect" : "Stop", role: .destructive) { Task { await app.stop() } }
        }
    }
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
