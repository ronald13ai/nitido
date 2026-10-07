import XCTest
import QuartzCore
@testable import NitidoCapture

/// The capture time of a frame comes from ScreenCaptureKit's display time in mach ticks; the view's presented time
/// is in seconds of the clock CACurrentMediaTime() reads. Their difference is the latency on the strip, so a wrong
/// conversion (the ratio inverted, or ticks taken as nanoseconds) would show a huge or negative latency.
final class MachClockTests: XCTestCase {
    func testTicksConvertToTheClockCACurrentMediaTimeReads() {
        let clock = MachClock()
        for _ in 0..<100 {
            let before = CACurrentMediaTime()
            let seconds = Double(clock.nanoseconds(fromTicks: mach_absolute_time())) / 1e9
            let after = CACurrentMediaTime()
            XCTAssertGreaterThanOrEqual(seconds, before - 0.000_01)
            XCTAssertLessThanOrEqual(seconds, after + 0.000_01)
        }
    }

    func testOneSecondOfTicksIsOneSecond() {
        let clock = MachClock()
        let ticksPerSecond = 1_000_000_000 * clock.denom / clock.numer
        XCTAssertEqual(Double(clock.nanoseconds(fromTicks: ticksPerSecond)), 1e9, accuracy: 1_000)
    }

    /// A display time a month into the uptime converts without overflowing and stays exact to the microsecond.
    func testLongUptimeConverts() {
        let clock = MachClock()
        let month: UInt64 = 30 * 86_400 * 1_000_000_000
        let ticks = month * clock.denom / clock.numer
        XCTAssertEqual(Double(clock.nanoseconds(fromTicks: ticks)), Double(month), accuracy: 1_000)
    }
}
