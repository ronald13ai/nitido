import SwiftUI

public struct WelcomeView: View {
    let onShare: () -> Void
    let onView: () -> Void
    public init(onShare: @escaping () -> Void, onView: @escaping () -> Void) { self.onShare = onShare; self.onView = onView }

    public var body: some View {
        VStack(spacing: 18) {
            Text("Nítido").font(Theme.Fonts.wordmark(52)).foregroundStyle(Theme.Colors.text)
            Text("Share a screen to another Mac. Crisp text, measured latency, ink on top.")
                .font(.system(size: 13)).foregroundStyle(Theme.Colors.muted)
            HStack(spacing: 12) {
                Button("Share", action: onShare).keyboardShortcut("n")
                Button("View", action: onView).disabled(true)   // enabled in Task 13
            }
            .padding(.top, 6)
            Text("BY RONALD RODRÍGUEZ · RONAR AI").font(Theme.Fonts.smallCaps(10)).foregroundStyle(Theme.Colors.gold).tracking(2).padding(.top, 10)
        }
        .padding(48).frame(width: 560, height: 360)
        .background(Theme.Colors.background)
    }
}
