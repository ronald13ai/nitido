import XCTest
@testable import NitidoCapture

/// A main-actor latch the test opens by hand, so an operation can be held suspended mid-await.
@MainActor
private final class Gate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func open() {
        isOpen = true
        waiter?.resume()
        waiter = nil
    }
}

@MainActor
private final class Trace {
    var items: [String] = []
}

final class SerialOperationsTests: XCTestCase {
    /// Lets every runnable main-actor task make progress.
    @MainActor
    private func drain() async {
        for _ in 0..<50 { await Task.yield() }
    }

    /// A stop enqueued while a start is suspended in an await must not run until the start finishes.
    @MainActor
    func testLaterOperationWaitsForSuspendedEarlierOne() async {
        let operations = SerialOperations()
        let gate = Gate()
        let trace = Trace()

        operations.enqueue {
            trace.items.append("start begins")
            await gate.wait()
            trace.items.append("start ends")
        }
        let stop = operations.enqueue { trace.items.append("stop") }

        await drain()
        XCTAssertEqual(trace.items, ["start begins"])

        gate.open()
        await stop.value
        XCTAssertEqual(trace.items, ["start begins", "start ends", "stop"])
    }

    /// Operations run in the order they were enqueued, even when each one suspends.
    @MainActor
    func testOperationsRunInEnqueueOrder() async {
        let operations = SerialOperations()
        let trace = Trace()

        for index in 0..<5 {
            operations.enqueue {
                trace.items.append("begin \(index)")
                await Task.yield()
                trace.items.append("end \(index)")
            }
        }
        await operations.enqueue {}.value

        XCTAssertEqual(trace.items, (0..<5).flatMap { ["begin \($0)", "end \($0)"] })
    }
}
