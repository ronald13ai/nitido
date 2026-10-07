import SwiftUI
import AppKit
import QuartzCore
import NitidoCore
import NitidoCapture

/// What `ShareModel` needs from a capture session. `CaptureSession` is the real one; tests use a fake.
@MainActor
protocol CaptureSource: AnyObject {
    var frames: AsyncStream<CapturedFrame> { get }
    var events: AsyncStream<CaptureEvent> { get }
    func presentPicker(excludingWindowIDs: [CGWindowID])
    func stop() async
}

extension CaptureSession: CaptureSource {}

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
    /// True when the current failure most likely comes from a missing Screen Recording grant, so System Settings is the fix.
    public private(set) var failureNeedsPermission = false
    /// The last reason a frame could not be rendered; cleared by the next frame that reaches the screen.
    public private(set) var renderFailure: String?

    private let makeSource: @MainActor () -> any CaptureSource
    /// The session of the current attempt. Each attempt gets a fresh one: a session's streams end for good
    /// once a task iterating them is cancelled, so a retired session is never reused.
    private var capture: (any CaptureSource)?
    private var excludedWindowIDs: [CGWindowID] = []
    private var telemetry = Telemetry(now: CACurrentMediaTime())
    private var tasks: [Task<Void, Never>] = []
    /// Bumped by every start and stop, so a start that waited for an earlier stop knows when it was superseded.
    private var attempt: UInt64 = 0
    /// Stops of retired sessions, chained in order across every ShareModel. `SCContentSharingPicker.shared`
    /// is one per process, so a new session waits for all of them before it touches the picker; otherwise
    /// a late stop would deactivate the new session's picker or leave an old observer starting streams.
    private static var retiring: Task<Void, Never>?

    public convenience init() { self.init(makeSource: { CaptureSession() }) }

    init(makeSource: @escaping @MainActor () -> any CaptureSource) {
        self.makeSource = makeSource
        sink.onPresented = { [weak self] captureNs, presentedAt in
            guard let self else { return }
            telemetry.recordDisplay(at: presentedAt)
            telemetry.recordLatency(ms: (presentedAt - Double(captureNs) / 1e9) * 1000, at: presentedAt)
            if renderFailure != nil { renderFailure = nil }
        }
        sink.onDropped = { [weak self] drop in
            guard let self else { return }
            switch drop {
            case .hidden:
                return
            case .backlog, .noDrawable, .notPresented:
                telemetry.recordDrop(at: CACurrentMediaTime())
            case .failed(let reason):
                telemetry.recordDrop(at: CACurrentMediaTime())
                if renderFailure != reason { renderFailure = reason }
            }
        }
    }

    public var resolutionLabel: String {
        guard pixelSize != .zero else { return "·" }
        let base = "\(Int(pixelSize.width))×\(Int(pixelSize.height)) @\(Int(scale))x"
        let f = fitFactor
        return f < 1 ? "\(base) · \(Int((f * 100).rounded()))%" : base
    }

    /// The content's point size at 1:1 on this view's screen.
    private var naturalPointSize: CGSize {
        sink.view?.pointSize(forPixelSize: pixelSize) ?? CGSize(width: pixelSize.width / scale, height: pixelSize.height / scale)
    }

    /// Room for the picture on the window's screen, leaving space for the title bar, the strip and a margin.
    private var pictureLimit: CGSize? {
        guard let screen = sink.view?.window?.screen ?? NSScreen.main else { return nil }
        return CGSize(width: screen.visibleFrame.width - 40, height: screen.visibleFrame.height - 120)
    }

    private var fitFactor: CGFloat {
        guard pixelSize != .zero, let limit = pictureLimit else { return 1 }
        return Fit.factor(natural: naturalPointSize, limit: limit)
    }

    /// 1:1 when it fits the screen, scaled down otherwise (VideoView then draws it with Lanczos), never up.
    public var fittedPointSize: CGSize {
        guard pixelSize != .zero else { return CGSize(width: 720, height: 450) }
        guard let limit = pictureLimit else { return naturalPointSize }
        return Fit.size(natural: naturalPointSize, limit: limit)
    }

    /// Shows the system picker. Ignored while picking or capturing; after a cancel or a failure it stops
    /// the old session first and starts a fresh one, so a second Share never leaves a session behind.
    public func start(excludingWindowIDs: [CGWindowID]) {
        if case .picking = state { return }
        if case .capturing = state { return }
        excludedWindowIDs = excludingWindowIDs
        failureNeedsPermission = false
        renderFailure = nil
        state = .picking
        attempt &+= 1
        let current = attempt
        retireSession()
        guard let earlier = Self.retiring else { beginSession(); return }
        Task { [weak self] in
            await earlier.value
            guard let self, attempt == current, state == .picking else { return }
            beginSession()
        }
    }

    /// After a failure: stops the old session and shows the picker again with the same windows excluded.
    public func retry() {
        guard case .failed = state else { return }
        start(excludingWindowIDs: excludedWindowIDs)
    }

    private func beginSession() {
        let session = makeSource()
        capture = session
        // The loops hold the model weakly: a session's streams never finish on their own, so a strong
        // reference here would keep every model alive for as long as the process runs.
        tasks = [
            Task { [weak self] in
                for await event in session.events {
                    guard let self else { return }
                    handle(event)
                }
            },
            Task { [weak self] in
                for await frame in session.frames {
                    guard let self else { return }
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
        session.presentPicker(excludingWindowIDs: excludedWindowIDs)
    }

    /// Cancels the current session's loops and queues its stop behind every earlier one.
    private func retireSession() {
        tasks.forEach { $0.cancel() }
        tasks = []
        guard let old = capture else { return }
        capture = nil
        let earlier = Self.retiring
        Self.retiring = Task { @MainActor in
            await earlier?.value
            await old.stop()
        }
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
            // Before the first frame, a missing Screen Recording grant is the likely cause.
            failureNeedsPermission = state != .capturing && !CGPreflightScreenCaptureAccess()
            state = .failed(message)
        }
    }

    /// Stops capture. Returns once this model's sessions, and every session retired before them, have stopped.
    public func stop() async {
        attempt &+= 1
        retireSession()
        // Idle at once: the loops are cancelled and the session is queued to stop, so a start that lands
        // while this waits proceeds (behind the stop) instead of being ignored or reset to idle afterwards.
        state = .idle
        await Self.retiring?.value
    }
}
