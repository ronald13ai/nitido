import SwiftUI
import AppKit
import NitidoUI

@main
struct NitidoApp: App {
    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        FontLoader.registerBundledFonts()
    }

    var body: some Scene {
        WindowGroup("Nítido") {
            VStack(spacing: 8) {
                Text("Nítido").font(Theme.Fonts.wordmark(44)).foregroundStyle(Theme.Colors.text)
                Text("BY RONALD RODRÍGUEZ · RONAR AI").font(Theme.Fonts.smallCaps(11))
                    .foregroundStyle(Theme.Colors.gold)
            }
            .frame(minWidth: 480, minHeight: 320)
            .background(Theme.Colors.background)
            .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
        }
        .windowResizability(.contentSize)
    }
}
