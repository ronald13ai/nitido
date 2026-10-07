import XCTest
import AppKit
import SwiftUI
import NitidoCapture
@testable import NitidoUI

/// A capture source that never sends anything: the share stays idle, which is enough to lay out the picture area.
@MainActor
private final class SilentSource: CaptureSource {
    let frames = AsyncStream<CapturedFrame> { _ in }
    let events = AsyncStream<CaptureEvent> { _ in }
    func presentPicker(excludingWindowIDs: [CGWindowID]) {}
    func stop() async {}
}

/// Takes the first click like a window of the active app does. The test process cannot become active, and without
/// this AppKit keeps every click on an inactive window for activating it, so no drag would reach SwiftUI at all.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class DividerHandleTests: XCTestCase {
    /// Lets SwiftUI lay out and handle the events sent so far (the main run loop turns while the test sleeps).
    @MainActor
    private func settle(_ view: NSView) async {
        for _ in 0..<6 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
        view.layoutSubtreeIfNeeded()
    }

    @MainActor
    private func send(_ type: NSEvent.EventType, at point: NSPoint, to window: NSWindow) {
        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
        else { return XCTFail("could not make a \(type) event") }
        window.sendEvent(event)
    }

    /// Drags from `start` (in the picture's top left coordinates) to the right by `dx` points, in four steps.
    @MainActor
    private func drag(from start: CGPoint, by dx: CGFloat, in host: NSView, window: NSWindow) async {
        let origin = host.convert(start, to: nil)
        send(.leftMouseDown, at: origin, to: window)
        await settle(host)
        for step in 1...4 {
            send(.leftMouseDragged, at: NSPoint(x: origin.x + dx * CGFloat(step) / 4, y: origin.y), to: window)
            await settle(host)
        }
        send(.leftMouseUp, at: NSPoint(x: origin.x + dx, y: origin.y), to: window)
        await settle(host)
    }

    /// The gold dot is the visible handle, where a user grabs the divider. A drag that starts on it moves the
    /// divider as one that starts elsewhere on the picture does: the dot must not take the drag from the handle
    /// under it. Checked in the Share view itself, with the panels above the handle.
    @MainActor
    func testDragStartingOnTheGoldDotMovesTheDivider() async throws {
        _ = NSApplication.shared
        let model = ShareModel(makeSource: { SilentSource() }, screenRecordingGranted: { true })
        model.loopback = true
        let picture = model.fittedPointSize
        let host = FirstMouseHostingView(rootView: ShareView(model: model))
        // On screen as far as AppKit knows (events reach only a window that is ordered in), but out of sight.
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: picture.width, height: picture.height + 80),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        await settle(host)

        // Off the dot first: the handle works at all in this setup.
        await drag(from: CGPoint(x: picture.width * 0.5, y: picture.height * 0.5), by: -picture.width * 0.25, in: host, window: window)
        XCTAssertEqual(model.dividerPosition, 0.25, accuracy: 0.01, "a drag off the dot moves the divider")

        // On the dot: it sits at the divider, 18 pt above the picture's bottom edge.
        let dot = CGPoint(x: picture.width * model.dividerPosition, y: picture.height - 18)
        await drag(from: dot, by: picture.width * 0.5, in: host, window: window)
        XCTAssertEqual(model.dividerPosition, 0.75, accuracy: 0.01, "a drag that starts on the gold dot moves the divider")
    }
}
