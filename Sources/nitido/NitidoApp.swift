import SwiftUI
import AppKit
import NitidoUI
import NitidoCapture

@main
struct NitidoApp: App {
    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        FontLoader.registerBundledFonts()
    }
    var body: some Scene {
        WindowGroup("Nítido") { CaptureProbe().frame(minWidth: 480, minHeight: 320).background(Theme.Colors.background) }
    }
}

@MainActor
private final class Probe: ObservableObject {
    @Published var status = "Idle"
    private let session = CaptureSession()
    private var count = 0
    private var startedAt = CACurrentMediaTime()

    func start() {
        Task {
            for await e in session.events {
                switch e {
                case .started(let w, let h, let s): status = "Capturing \(w)x\(h) @\(s)x"; startedAt = CACurrentMediaTime(); count = 0
                case .cancelled: status = "Cancelled"
                case .stopped: status = "Stopped"
                case .failed(let m): status = "Failed: \(m)"
                }
            }
        }
        Task {
            for await f in session.frames {
                count += 1
                if count % 30 == 0 {
                    let fps = Double(count) / (CACurrentMediaTime() - startedAt)
                    status = "\(f.pixelWidth)x\(f.pixelHeight) · \(count) frames · \(Int(fps.rounded())) fps · age \(Int((CACurrentMediaTime() - Double(f.captureHostTimeNs) / 1e9) * 1000)) ms"
                }
            }
        }
        session.presentPicker(excludingWindowIDs: NSApp.windows.map { CGWindowID($0.windowNumber) })
    }
}

private struct CaptureProbe: View {
    @StateObject private var probe = Probe()
    var body: some View {
        VStack(spacing: 12) {
            Text(probe.status).font(Theme.Fonts.figures(13)).foregroundStyle(Theme.Colors.text)
            Button("Pick a window") { probe.start() }
        }.padding(40).onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
    }
}
