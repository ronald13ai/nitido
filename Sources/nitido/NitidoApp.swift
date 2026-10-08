import SwiftUI
import AppKit
import NitidoUI

@main
struct NitidoApp: App {
    @State private var app = AppModel()

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
                .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
        }
        .windowResizability(.contentSize)
        .commands {
            // The standard group owns ⌘H for Hide, which would swallow Toggle Telemetry's ⌘H.
            CommandGroup(replacing: .appVisibility) {
                Button("Hide Nítido") { NSApp.hide(nil) }
                Button("Hide Others") { NSApp.hideOtherApplications(nil) }.keyboardShortcut("h", modifiers: [.command, .option])
                Button("Show All") { NSApp.unhideAllApplications(nil) }
            }
            // The standard Undo owns ⌘Z, and SwiftUI then drops ⌘Z from Undo Stroke, so ⌘Z would do nothing.
            CommandGroup(replacing: .undoRedo) {}
            CommandMenu("Nítido") {
                Button("Share…") { app.startShare() }.keyboardShortcut("n")
                // ⌘⇧V, not ⌘V: SwiftUI gives a shortcut to one menu item only, so ⌘V here would take Paste away from
                // the whole app, the code field included.
                Button("View…") { app.startView() }.keyboardShortcut("v", modifiers: [.command, .shift])
                Button("Toggle Telemetry") { app.toggleTelemetry() }.keyboardShortcut("h")
                Button("Codec Loop") { app.toggleLoopback() }.keyboardShortcut("l")
                Button("Undo Stroke") { app.undo() }.keyboardShortcut("z")
                Button("Clear Ink") { app.clearInk() }.keyboardShortcut(.delete)
                // Listed for discoverability; while the window is key, Esc is handled inside it (RootView). Both go
                // through `escape()`, which asks "Stop sharing?" or "Disconnect?" first while something is live.
                Button("Stop") { app.escape() }.keyboardShortcut(.escape, modifiers: [])
            }
        }
    }
}
