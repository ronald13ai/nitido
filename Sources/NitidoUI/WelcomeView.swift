import SwiftUI

public struct WelcomeView: View {
    let onShare: () -> Void
    let onView: () -> Void
    public init(onShare: @escaping () -> Void, onView: @escaping () -> Void) { self.onShare = onShare; self.onView = onView }

    public var body: some View {
        ZStack {
            Theme.Colors.background
            GlassCard {
                VStack(spacing: 16) {
                    Text("Nítido").font(Theme.Fonts.wordmark(56)).foregroundStyle(Theme.Colors.text).appear()
                    Text("Share a screen to another Mac. Crisp text, measured latency, ink on top.")
                        .font(.system(size: 13)).foregroundStyle(Theme.Colors.secondaryText).appear(delay: Theme.Motion.stagger)
                    HStack(spacing: 12) {
                        GoldButton("Share", action: onShare)
                        QuietButton("View", action: onView)
                    }.padding(.top, 6).appear(delay: Theme.Motion.stagger * 2)
                    Text("BY RONALD RODRÍGUEZ · RONAR AI").font(Theme.Fonts.smallCaps(10)).foregroundStyle(Theme.Colors.gold).tracking(2)
                        .padding(.top, 10).appear(delay: Theme.Motion.stagger * 3)
                }
                .padding(.horizontal, 44).padding(.vertical, 36)
            }
        }
        .frame(width: 600, height: 400)
    }
}
