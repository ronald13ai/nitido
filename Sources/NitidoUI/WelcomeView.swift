import SwiftUI

/// The first screen: one solid card on the maison black, with a faint gold warmth behind it. Glass over flat black
/// bends nothing (it showed as a faint rim when the window was key and a grey slab when it was not), so the card is the
/// surface with a hairline and a highlight along its top edge. On the 8 pt grid: wordmark, 8, subtitle, 24, buttons,
/// 32, credit, inside 48 by 40.
public struct WelcomeView: View {
    let onShare: () -> Void
    let onView: () -> Void
    public init(onShare: @escaping () -> Void, onView: @escaping () -> Void) { self.onShare = onShare; self.onView = onView }

    public var body: some View {
        ZStack {
            // Under the transparent title bar too, so the black and its warmth run to the window's edges.
            Theme.Colors.background.ignoresSafeArea()
            RadialGradient(colors: [Theme.Colors.gold.opacity(0.07), .clear], center: .center, startRadius: 0, endRadius: 340)
                .ignoresSafeArea()
            SolidCard {
                VStack(spacing: 0) {
                    // At 56 pt the í's acute nearly touches the N's top serif ("Ńtido" at a glance): 2.5 pt between them.
                    Text("\(Text("N").kerning(2.5))ítido").font(Theme.Fonts.wordmark(56)).foregroundStyle(Theme.Colors.cream)
                        .accessibilityLabel("Nítido")
                        .appear()
                    Text("Share a screen to another Mac. Crisp text, measured latency, ink on top.")
                        .font(.system(size: 13)).foregroundStyle(Theme.Colors.secondaryText)
                        .padding(.top, 8)
                        .appear(delay: Theme.Motion.stagger)
                    HStack(spacing: 12) {
                        GoldButton("Share", action: onShare)
                        QuietButton("View", action: onView)
                    }
                    .padding(.top, 24)
                    .appear(delay: Theme.Motion.stagger * 2)
                    Text("BY RONALD RODRÍGUEZ · RONAR AI").font(Theme.Fonts.smallCaps(10)).foregroundStyle(Theme.Colors.gold).tracking(2)
                        .padding(.top, 32)
                        .appear(delay: Theme.Motion.stagger * 3)
                }
                .padding(.horizontal, 48).padding(.vertical, 40)
            }
        }
        .frame(width: 600, height: 400)
    }
}
