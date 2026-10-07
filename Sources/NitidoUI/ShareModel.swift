import SwiftUI
import AppKit
import QuartzCore
import NitidoCore
import NitidoCapture

@MainActor @Observable
public final class ShareModel {
    public enum State: Equatable { case idle, picking, capturing, failed(String) }

    public private(set) var state: State = .idle
    public private(set) var snapshot: Snapshot = .empty
    public private(set) var pixelSize: CGSize = .zero
    public private(set) var scale: CGFloat = 2
    public var showTelemetry = true
    public let sink = FrameSink()
    public let code = Pairing.makeCode()
    public let name = Host.current().localizedName ?? "Mac"

    private let capture = CaptureSession()
    private var telemetry = Telemetry(now: CACurrentMediaTime())
    private var tasks: [Task<Void, Never>] = []

    public init() {
        sink.onPresented = { [weak self] captureNs, presentedAt in
            guard let self else { return }
            telemetry.recordDisplay(at: presentedAt)
            telemetry.recordLatency(ms: (presentedAt - Double(captureNs) / 1e9) * 1000, at: presentedAt)
        }
    }

    public var resolutionLabel: String {
        pixelSize == .zero ? "·" : "\(Int(pixelSize.width))×\(Int(pixelSize.height)) @\(Int(scale))x"
    }

    public func start(excludingWindowIDs: [CGWindowID]) {
        if case .picking = state { return }
        if case .capturing = state { return }
        state = .picking
        tasks.forEach { $0.cancel() }
        tasks = [
            Task { [weak self] in
                guard let self else { return }
                for await event in capture.events { handle(event) }
            },
            Task { [weak self] in
                guard let self else { return }
                for await frame in capture.frames {
                    telemetry.recordCapture(at: Double(frame.captureHostTimeNs) / 1e9)
                    sink.push(frame.pixelBuffer, captureHostTimeNs: frame.captureHostTimeNs)
                }
            },
            Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard let self else { return }
                    snapshot = telemetry.snapshot(now: CACurrentMediaTime())
                }
            },
        ]
        capture.presentPicker(excludingWindowIDs: excludingWindowIDs)
    }

    private func handle(_ event: CaptureEvent) {
        switch event {
        case .started(let w, let h, let s):
            pixelSize = CGSize(width: w, height: h); scale = s; state = .capturing
        case .cancelled:
            state = .idle
        case .stopped:
            state = .idle
        case .failed(let message):
            state = .failed(message)
        }
    }

    public func stop() async {
        tasks.forEach { $0.cancel() }
        tasks = []
        await capture.stop()
        state = .idle
    }
}
