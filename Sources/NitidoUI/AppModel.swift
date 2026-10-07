import SwiftUI
import AppKit

@MainActor @Observable
public final class AppModel {
    public enum Screen: Equatable { case welcome, share, view }
    public var screen: Screen = .welcome
    public private(set) var share: ShareModel?
    public init() {}

    public func startShare() {
        let model = ShareModel()
        share = model
        screen = .share
        model.start(excludingWindowIDs: NSApp.windows.filter { $0.windowNumber > 0 }.map { CGWindowID($0.windowNumber) })
    }

    public func toggleTelemetry() { share?.showTelemetry.toggle() }

    public func stop() async {
        await share?.stop()
        share = nil
        screen = .welcome
    }
}

public struct RootView: View {
    @Bindable var app: AppModel
    public init(app: AppModel) { self.app = app }
    public var body: some View {
        switch app.screen {
        case .welcome: WelcomeView(onShare: { app.startShare() }, onView: {})
        case .share: if let share = app.share { ShareView(model: share) }
        case .view: Text("View").foregroundStyle(Theme.Colors.text)   // Task 13
        }
    }
}
