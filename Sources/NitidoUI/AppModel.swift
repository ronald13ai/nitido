import SwiftUI
import AppKit

@MainActor @Observable
public final class AppModel {
    public enum Screen: Equatable { case welcome, share, view }
    public var screen: Screen = .welcome
    public private(set) var share: ShareModel?
    public private(set) var view: ViewModel?
    public init() {}

    /// Shows the Share screen and the picker. One share at a time: while a share is picking or capturing this
    /// does nothing more; after a cancel or a failure it reuses the same model, which stops its old session first.
    public func startShare() {
        let excluded = NSApp.windows.filter { $0.windowNumber > 0 }.map { CGWindowID($0.windowNumber) }
        screen = .share
        if let share {
            share.start(excludingWindowIDs: excluded)
            return
        }
        let model = ShareModel()
        share = model
        model.start(excludingWindowIDs: excluded)
    }

    /// Shows the View screen. One viewer at a time: a viewer that exists already (browsing, connected or failed) is
    /// kept, so ⌘V twice never leaves a replaced viewer's link open with nobody to close it.
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

    /// The one entry point for Esc: the invisible in-window button on the Share and View screens and the Stop
    /// menu item both call it. It stops at once for now; Task 15 makes it call `requestStop()`, so Esc asks
    /// "Stop sharing?" or "Disconnect?" first whether or not the window is key.
    public func escape() { Task { await stop() } }
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
    }
}

/// Esc inside the window. A menu item's Esc shortcut never fires while a window is key, so the Share and
/// View screens carry this invisible button; Welcome does not, so Esc there does nothing. It must call
/// `app.escape()`, never `app.stop()` directly, so the confirmation Task 15 adds also covers it.
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
