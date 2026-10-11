import SwiftUI
import AppKit
import NitidoUI

/// Holds the app's model so a quit can stop a live session first: ⌘Q, and the window closing, which quits the app.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let app = AppModel()

    /// A live share or viewer says `bye` to the other Mac before the process ends (`AppModel.shouldQuitNow`). ⌘Q, ⌘W and
    /// the close button ask first (`AppModel.requestQuit`) and come here with nothing live; the system's own quit (a
    /// logout, a restart, Quit in the Dock) comes straight here and asks nothing.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        app.shouldQuitNow { sender.reply(toApplicationShouldTerminate: true) } ? .terminateNow : .terminateLater
    }

    /// One window: closing it quits, through `applicationShouldTerminate`.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct NitidoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private var app: AppModel { delegate.app }

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        FontLoader.registerBundledFonts()
    }

    var body: some Scene {
        // A single window: a WindowGroup would add File > New Window on ⌘N (taking it from Share…) and let a
        // second window bind the same model, stealing the video view from the first.
        Window("Nítido", id: "main") {
            RootView(app: app)
                .background(Theme.Colors.background)
                // One dark family edge to edge: no grey title bar, no separator, no second "Nítido" above the
                // wordmark. The traffic lights float on the background.
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .toolbar(removing: .title)
                .containerBackground(Theme.Colors.background, for: .window)
                .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
        }
        .windowResizability(.contentSize)
        // Every item sits in a standard menu, so the menu bar shows Nítido once, as the app menu (macOS HIG).
        .commands {
            // File. Share… and View… take the place of New, which a single window has no use for.
            CommandGroup(replacing: .newItem) {
                Button("Share…") { app.startShare() }.keyboardShortcut("n")
                // ⌘⇧V, not ⌘V: SwiftUI gives a shortcut to one menu item only, so ⌘V here would take Paste away from
                // the whole app, the code field included.
                Button("View…") { app.startView() }.keyboardShortcut("v", modifiers: [.command, .shift])
            }
            CommandGroup(after: .newItem) {
                Divider()
                // Listed for discoverability; while the window is key, Esc is handled inside it (RootView). Both go
                // through `escape()`, which asks "Stop sharing?" or "Disconnect?" first while a capture or a connected viewer is live, and cancels the share alone when only the picker or a failure card is up with a viewer open.
                Button(app.menu.stopTitle) { app.escape() }.keyboardShortcut(.escape, modifiers: [])
                    .disabled(!app.menu.canStop)
            }
            // ⌘Q asks first while something is live, as Esc and the close button do (`AppModel.requestQuit`).
            CommandGroup(replacing: .appTermination) {
                Button("Quit Nítido") { app.requestQuit() }.keyboardShortcut("q")
            }
            // The app menu. The standard group owns ⌘H for Hide, which would swallow Toggle Telemetry's ⌘H.
            CommandGroup(replacing: .appVisibility) {
                Button("Hide Nítido") { NSApp.hide(nil) }
                Button("Hide Others") { NSApp.hideOtherApplications(nil) }.keyboardShortcut("h", modifiers: [.command, .option])
                Button("Show All") { NSApp.unhideAllApplications(nil) }
            }
            // Edit. The standard Undo owns ⌘Z, and SwiftUI then drops ⌘Z from Undo Stroke, so ⌘Z would do nothing:
            // the ink's own items take its place.
            CommandGroup(replacing: .undoRedo) {
                Button("Undo Stroke") { app.undo() }.keyboardShortcut("z").disabled(!app.menu.canInk)
                Button("Clear Ink") { app.clearInk() }.keyboardShortcut(.delete).disabled(!app.menu.canInk)
            }
            // View.
            CommandGroup(before: .toolbar) {
                Button("Toggle Telemetry") { app.toggleTelemetry() }.keyboardShortcut("h").disabled(!app.menu.canToggleTelemetry)
                Button("Codec Loop") { app.toggleLoopback() }.keyboardShortcut("l").disabled(!app.menu.canToggleLoop)
                Divider()
            }
        }
    }
}
