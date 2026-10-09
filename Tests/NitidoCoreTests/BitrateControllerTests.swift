import XCTest
@testable import NitidoCore

final class BitrateControllerTests: XCTestCase {
    /// One frame of bytes at 20 Mbps and 60 fps, rounded up: neither healthy nor congested.
    private let oneFrame = 41_667

    func testInitialBitrateScalesWithPixels() {
        XCTAssertEqual(BitrateController.initialBitrate(width: 1920, height: 1080), 20_000_000)
        XCTAssertEqual(BitrateController.initialBitrate(width: 1280, height: 720), 8_888_888)
        // The second two-Mac test's window, 1346×878 pt at 2x: as many bits per pixel as 20 Mbps at 1080p.
        XCTAssertEqual(BitrateController.initialBitrate(width: 2692, height: 1756), 45_593_672)
        XCTAssertEqual(BitrateController.initialBitrate(width: 5120, height: 2880), 60_000_000)
        XCTAssertEqual(BitrateController.initialBitrate(width: 100, height: 100), 2_000_000)
    }

    func testHealthyLinkRaisesTenPercentEveryTwoSeconds() {
        var c = BitrateController(initial: 20_000_000)
        XCTAssertEqual(c.update(rttMs: 10, backlogBytes: 0, frameAgeMs: nil, fps: 60, now: 0), 22_000_000)
        XCTAssertEqual(c.update(rttMs: 10, backlogBytes: 0, frameAgeMs: nil, fps: 60, now: 1), 22_000_000)
        XCTAssertEqual(c.update(rttMs: 10, backlogBytes: 0, frameAgeMs: nil, fps: 60, now: 2), 24_200_000)
        XCTAssertEqual(c.update(rttMs: 10, backlogBytes: 0, frameAgeMs: nil, fps: 60, now: 3), 24_200_000)
        XCTAssertEqual(c.update(rttMs: 10, backlogBytes: 0, frameAgeMs: nil, fps: 60, now: 4), 26_620_000)
    }

    func testBacklogCutsAQuarterThenHoldsTwoSeconds() {
        var c = BitrateController(initial: 20_000_000)
        // Multiply before dividing so `twoFrames + 1` is the first whole byte over two frames (83 333.3).
        let twoFrames = 20_000_000 * 2 / 8 / 60
        XCTAssertEqual(c.update(rttMs: 10, backlogBytes: twoFrames + 1, frameAgeMs: nil, fps: 60, now: 0), 15_000_000)
        XCTAssertEqual(c.update(rttMs: 10, backlogBytes: twoFrames + 1, frameAgeMs: nil, fps: 60, now: 1), 15_000_000)
        XCTAssertEqual(c.update(rttMs: 10, backlogBytes: twoFrames + 1, frameAgeMs: nil, fps: 60, now: 2), 11_250_000)
    }

    /// Congestion right after a 10% step-up, the likeliest moment for it, cuts at once: only a cut holds for 2 s.
    func testCongestionRightAfterARaiseCutsAtOnce() {
        var c = BitrateController(initial: 20_000_000)
        XCTAssertEqual(c.update(rttMs: 10, backlogBytes: 0, frameAgeMs: nil, fps: 60, now: 0), 22_000_000)
        // The first whole byte over two frames at 22 Mbps (91 666.7).
        let overTwoFrames = 22_000_000 * 2 / 8 / 60 + 1
        XCTAssertEqual(c.update(rttMs: 10, backlogBytes: overTwoFrames, frameAgeMs: nil, fps: 60, now: 0.25), 16_500_000)
        XCTAssertEqual(c.update(rttMs: 10, backlogBytes: overTwoFrames, frameAgeMs: nil, fps: 60, now: 1), 16_500_000)
        XCTAssertEqual(c.update(rttMs: 10, backlogBytes: overTwoFrames, frameAgeMs: nil, fps: 60, now: 2.25), 12_375_000)
    }

    /// Spec 8: frames the sender skipped for its backlog since the last update are congestion, and the cut they bring
    /// does not wait out the 2 s hold of an earlier cut: by the time the sender skips, its backlog has been over 150 ms
    /// worth for 100 ms (`BacklogPolicy`). One cut per update that reports a skip; the hold counts again from it.
    func testFramesSkippedForTheBacklogCutAtOnceEvenWithinTheHold() {
        var c = BitrateController(initial: 20_000_000)
        let twoFrames = 20_000_000 * 2 / 8 / 60
        XCTAssertEqual(c.update(rttMs: 10, backlogBytes: twoFrames + 1, frameAgeMs: nil, fps: 60, now: 0), 15_000_000)
        XCTAssertEqual(c.update(rttMs: 10, backlogBytes: twoFrames + 1, frameAgeMs: nil, fps: 60, now: 0.25), 15_000_000,
                       "the backlog alone waits out the hold")
        XCTAssertEqual(c.update(rttMs: 10, backlogBytes: twoFrames + 1, frameAgeMs: nil, fps: 60, now: 0.5, skippedForBacklog: true),
                       11_250_000, "a skip does not")
        XCTAssertEqual(c.update(rttMs: 10, backlogBytes: twoFrames + 1, frameAgeMs: nil, fps: 60, now: 2.25), 11_250_000,
                       "the hold counts from the skip's cut")
        XCTAssertEqual(c.update(rttMs: 10, backlogBytes: twoFrames + 1, frameAgeMs: nil, fps: 60, now: 2.5), 8_437_500)
    }

    /// A skip is congestion even when the backlog has drained by the update and the RTT is at its baseline: the rate is
    /// cut, not raised, and the next raise waits 2 s from that cut.
    func testASkipCutsWhateverTheOtherInputsSay() {
        var c = BitrateController(initial: 20_000_000)
        XCTAssertEqual(c.update(rttMs: 10, backlogBytes: 0, frameAgeMs: nil, fps: 60, now: 0, skippedForBacklog: true), 15_000_000)
        XCTAssertEqual(c.update(rttMs: 10, backlogBytes: 0, frameAgeMs: nil, fps: 60, now: 1), 15_000_000)
        XCTAssertEqual(c.update(rttMs: 10, backlogBytes: 0, frameAgeMs: nil, fps: 60, now: 2), 16_500_000)
    }

    func testNoRaiseWithinTwoSecondsOfACut() {
        var c = BitrateController(initial: 20_000_000)
        let twoFrames = 20_000_000 * 2 / 8 / 60
        XCTAssertEqual(c.update(rttMs: 10, backlogBytes: twoFrames + 1, frameAgeMs: nil, fps: 60, now: 0), 15_000_000)
        XCTAssertEqual(c.update(rttMs: 10, backlogBytes: 0, frameAgeMs: nil, fps: 60, now: 1), 15_000_000)
        XCTAssertEqual(c.update(rttMs: 10, backlogBytes: 0, frameAgeMs: nil, fps: 60, now: 2), 16_500_000)
    }

    func testRTTAboveBaselinePlusFortyCuts() {
        var c = BitrateController(initial: 20_000_000)
        XCTAssertEqual(c.update(rttMs: 10, backlogBytes: oneFrame, frameAgeMs: nil, fps: 60, now: 0), 20_000_000)
        XCTAssertEqual(c.update(rttMs: 55, backlogBytes: 0, frameAgeMs: nil, fps: 60, now: 2), 15_000_000)
    }

    func testRTTSlightlyAboveBaselineLeavesRateAlone() {
        var c = BitrateController(initial: 20_000_000)
        XCTAssertEqual(c.update(rttMs: 10, backlogBytes: oneFrame, frameAgeMs: nil, fps: 60, now: 0), 20_000_000)
        XCTAssertEqual(c.update(rttMs: 30, backlogBytes: 0, frameAgeMs: nil, fps: 60, now: 2), 20_000_000)
    }

    func testStaleFrameAgeCuts() {
        var c = BitrateController(initial: 20_000_000)
        XCTAssertEqual(c.update(rttMs: nil, backlogBytes: 0, frameAgeMs: 200, fps: 60, now: 0), 15_000_000)
    }

    func testBoundsHold() {
        var c = BitrateController(initial: 3_000_000)
        for i in 0..<20 { _ = c.update(rttMs: nil, backlogBytes: 1_000_000, frameAgeMs: nil, fps: 60, now: Double(i * 3)) }
        XCTAssertEqual(c.bitsPerSecond, 2_000_000)
        var d = BitrateController(initial: 59_000_000)
        for i in 0..<20 { _ = d.update(rttMs: 10, backlogBytes: 0, frameAgeMs: nil, fps: 60, now: Double(i * 3)) }
        XCTAssertEqual(d.bitsPerSecond, 60_000_000)
    }
}
