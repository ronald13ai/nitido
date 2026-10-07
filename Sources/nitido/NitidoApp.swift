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
        WindowGroup("Nítido") {
            RootView(app: app)
                .background(Theme.Colors.background)
                .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandMenu("Nítido") {
                Button("Share…") { app.startShare() }.keyboardShortcut("n")
                Button("Toggle Telemetry") { app.toggleTelemetry() }.keyboardShortcut("h")
                Button("Stop") { Task { await app.stop() } }.keyboardShortcut(.escape, modifiers: [])
            }
        }
    }
}
