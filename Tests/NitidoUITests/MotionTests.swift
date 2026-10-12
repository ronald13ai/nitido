import XCTest
import AppKit
import SwiftUI
import NitidoCore
import NitidoCapture
@testable import NitidoUI

/// The motion's values and state (spec 11): the tokens the spec names, the curves as numbers, the Reduce Motion rule,
/// the staged entrances, the launch's glint once per process, the code's stagger, the ring once per connection, the
/// strip's hysteresis, and the direction of every change of screen.
final class MotionTokenTests: XCTestCase {
    private typealias M = Theme.Motion

    private func assertCurve(_ c: M.Curve, _ points: (Double, Double, Double, Double), _ duration: Double, _ name: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(c.x1, points.0, name, file: file, line: line); XCTAssertEqual(c.y1, points.1, name, file: file, line: line)
        XCTAssertEqual(c.x2, points.2, name, file: file, line: line); XCTAssertEqual(c.y2, points.3, name, file: file, line: line)
        XCTAssertEqual(c.duration, duration, accuracy: 1e-9, name, file: file, line: line)
    }

    /// Every token as the spec writes it.
    func testTheTokensAreTheSpecsValues() {
        let out = (0.23, 1.0, 0.32, 1.0), inOut = (0.77, 0.0, 0.175, 1.0)
        assertCurve(M.enter, out, 0.22, "enter")
        assertCurve(M.press, out, 0.12, "press")
        assertCurve(M.hover, (0.25, 0.1, 0.25, 1), 0.16, "hover: ease, a colour change")
        assertCurve(M.exit, (0, 0, 0.58, 1), 0.12, "exit")
        assertCurve(M.move, inOut, 0.24, "move")
        assertCurve(M.windowGrow, inOut, 0.30, "window grow")
        assertCurve(M.windowShrink, inOut, 0.26, "window shrink")
        assertCurve(M.focus, out, 0.24, "focus")
        XCTAssertEqual(M.focusBlur, 8)
        assertCurve(M.figure, out, 0.18, "figure")
        assertCurve(M.settle, (0.42, 0, 0.58, 1), 0.6, "settle")
        assertCurve(M.breathe, (0.42, 0, 0.58, 1), 1.2, "breathe, each way")
        assertCurve(M.shimmer, inOut, 0.76, "shimmer")
        XCTAssertEqual(M.shimmerDelay, 0.44, accuracy: 1e-9, "the glint ends at 1.2 s")
        assertCurve(M.reveal, inOut, 0.22, "reveal")
        XCTAssertEqual(M.connect, M.Spring(duration: 0.5, bounce: 0.2))
        XCTAssertEqual(M.alive, M.Spring(duration: 0.35, bounce: 0.3))
        XCTAssertEqual(M.grab, M.Spring(duration: 0.25, bounce: 0.2))
        XCTAssertEqual(M.letGo, M.Spring(duration: 0.3, bounce: 0))
        XCTAssertEqual(M.stagger, 0.04)
        XCTAssertEqual(M.enterScale, 0.96); XCTAssertEqual(M.screenScale, 0.98)
        XCTAssertEqual(M.pressScale, 0.97); XCTAssertEqual(M.pressScaleWide, 0.985)
        XCTAssertEqual(M.reconnectDim, 0.20); XCTAssertEqual(M.failureDim, 0.55)
    }

    /// Entrances stay under 250 ms, exits are faster than entrances, and nothing enters from scale 0.
    func testEntrancesAreQuickAndExitsQuicker() {
        for (name, c) in [("enter", M.enter), ("focus", M.focus), ("figure", M.figure), ("press", M.press)] {
            XCTAssertLessThan(c.duration, 0.25, name)
        }
        XCTAssertLessThan(M.exit.duration, M.enter.duration)
        XCTAssertLessThan(M.windowShrink.duration, M.windowGrow.duration, "the window closes in faster than it opens")
        XCTAssertGreaterThan(M.enterScale, 0.9); XCTAssertGreaterThan(M.screenScale, M.enterScale)
        // A 536 pt row and a 260 pt button give by about the same 4 pt a side.
        XCTAssertEqual(536 * (1 - M.pressScaleWide) / 2, 260 * (1 - M.pressScale) / 2, accuracy: 0.2)
    }

    /// A curve's value at a time: 0 before, 1 after, monotonic in between; the strong ease-out front-loads, the strong
    /// ease-in-out is symmetric and slow at both ends.
    func testCurvesAreReadAsValues() {
        for c in [M.enter, M.exit, M.move, M.hover, M.settle, M.windowGrow] {
            XCTAssertEqual(c.progress(at: -0.01), 0); XCTAssertEqual(c.progress(at: c.duration + 0.01), 1)
            var last = 0.0
            for step in 0...100 {
                let p = c.progress(at: c.duration * Double(step) / 100)
                XCTAssertGreaterThanOrEqual(p, last - 1e-6); last = p
            }
        }
        XCTAssertGreaterThan(M.enter.progress(at: M.enter.duration * 0.25), 0.7, "strong ease-out: most of the way in a quarter of the time")
        XCTAssertLessThan(M.move.progress(at: M.move.duration * 0.1), 0.02, "strong ease-in-out: a slow start")
        XCTAssertGreaterThan(M.move.progress(at: M.move.duration * 0.9), 0.99, "and a soft landing")
        // Against the Bézier solved another way: bisection on its parameter, for x every 5 %.
        func reference(_ c: M.Curve, _ x: Double) -> Double {
            func b(_ p1: Double, _ p2: Double, _ t: Double) -> Double { 3 * (1 - t) * (1 - t) * t * p1 + 3 * (1 - t) * t * t * p2 + t * t * t }
            var lo = 0.0, hi = 1.0
            for _ in 0..<60 { let mid = (lo + hi) / 2; if b(c.x1, c.x2, mid) < x { lo = mid } else { hi = mid } }
            return b(c.y1, c.y2, (lo + hi) / 2)
        }
        for c in [M.enter, M.move, M.hover, M.settle, M.exit] {
            for step in 1..<20 {
                let x = Double(step) / 20
                XCTAssertEqual(c.progress(at: c.duration * x), reference(c, x), accuracy: 1e-5)
            }
        }
    }

    /// Reduce Motion: the policy's answer when it has one, the system's otherwise; what moved becomes a fade, the focus
    /// pull (a blur, which moves nothing) stays.
    func testReduceMotionPolicy() {
        XCTAssertTrue(MotionPolicy().resolved(system: true)); XCTAssertFalse(MotionPolicy().resolved(system: false))
        XCTAssertTrue(MotionPolicy(reduceMotion: true).resolved(system: false))
        XCTAssertFalse(MotionPolicy(reduceMotion: false).resolved(system: true))
        XCTAssertEqual(EntranceMotion.compact.reduced(true), .fade)
        XCTAssertEqual(EntranceMotion.row.reduced(true), .fade)
        XCTAssertEqual(EntranceMotion.slide(6).reduced(true), .fade)
        XCTAssertEqual(EntranceMotion.focus(8).reduced(true), .focus(8))
        XCTAssertEqual(EntranceMotion.compact.reduced(false), .compact)
    }

    /// A staged element enters in its slot after its stage began; one built after its slot has passed (the strip shown
    /// again with ⌘H, a panel on a screen shown again) is simply there.
    func testAStagedEntrancePlaysOnceWithItsStage() {
        XCTAssertFalse(Entrance.isLate(delay: 0.16, since: 10, now: 10.01), "the strip built with its stage")
        XCTAssertFalse(Entrance.isLate(delay: 0.16, since: 10, now: 10.2), "a frame or two late still enters")
        XCTAssertTrue(Entrance.isLate(delay: 0.16, since: 10, now: 70), "⌘H a minute later: there at once")
        XCTAssertFalse(Entrance.isLate(delay: 0.16, since: nil, now: 70), "no stage: an ordinary entrance")
        XCTAssertEqual(Entrance.remainingDelay(0.16, since: 10, now: 10.06), 0.10, accuracy: 1e-9)
        XCTAssertEqual(Entrance.remainingDelay(0.16, since: 10, now: 10.3), 0)
        XCTAssertEqual(Entrance.remainingDelay(0.16, since: nil, now: 10.3), 0.16)
    }

    /// The picture's entrance on both Macs runs in the choreography's order, 40 ms apart.
    func testThePicturesEntranceIsInOrder() {
        let share = [ShareView.Stage.strip, ShareView.Stage.pairing, ShareView.Stage.loop, ShareView.Stage.code, ShareView.Stage.notices]
        XCTAssertEqual(share, [0.16, 0.20, 0.24, 0.28, 0.32])
        XCTAssertEqual(Theme.Motion.coverDelay, 0.04)
        let view = [ViewView.PictureStage.strip, ViewView.PictureStage.chip, ViewView.PictureStage.dot, ViewView.PictureStage.ring]
        XCTAssertEqual(view, [0.16, 0.20, 0.24, 0.26])
    }

    /// The window grows on the grow curve and shrinks on the shorter one; the frame that sizes it is the size shown, to
    /// the whole point, or the content's own before it has one.
    func testTheWindowsFrame() {
        XCTAssertEqual(AnimatedArea<EmptyView>.curve(from: CGSize(width: 600, height: 400), to: CGSize(width: 1440, height: 900)), M.windowGrow)
        XCTAssertEqual(AnimatedArea<EmptyView>.curve(from: CGSize(width: 1440, height: 900), to: CGSize(width: 600, height: 400)), M.windowShrink)
        XCTAssertEqual(RevealLayout.size(shown: nil, natural: CGSize(width: 1440, height: 948)), CGSize(width: 1440, height: 948))
        XCTAssertEqual(RevealLayout.size(shown: CGSize(width: 731.4, height: 512.6), natural: CGSize(width: 1440, height: 948)),
                       CGSize(width: 731, height: 513), "mid-growth, in whole points")
    }
}

final class LaunchMotionTests: XCTestCase {
    /// The launch's timeline: the warmth over 480 ms, the wordmark's focus at 60 ms, the rest 40 ms apart, the glint at
    /// 440 ms for 760 ms.
    func testTheLaunchTimeline() {
        XCTAssertEqual(LaunchChoreography.warmth.duration, 0.48)
        XCTAssertEqual([LaunchChoreography.wordmark, LaunchChoreography.subtitle, LaunchChoreography.buttons, LaunchChoreography.byline],
                       [0.06, 0.10, 0.14, 0.18])
        XCTAssertEqual(Theme.Motion.shimmerDelay + Theme.Motion.shimmer.duration, 1.2, accuracy: 1e-9)
        XCTAssertEqual(LaunchChoreography.visibilityFallback, 0.15)
    }

    /// The glint plays once per process: at launch, never on a return to Welcome, never under Reduce Motion.
    @MainActor
    func testTheShimmerPlaysOnce() {
        let app = AppModel(makeShare: { ShareModel(makeSource: { NeverSource() }, screenRecordingGranted: { true }) },
                           makeView: { ViewModel(startingDiscovery: false) }, terminate: {}, revealWindow: {}, hideWindows: {})
        XCTAssertFalse(app.launchPlayed)
        let first = LaunchChoreography.arrival(launchPlayed: app.launchPlayed)
        XCTAssertEqual(first, .launch)
        XCTAssertTrue(LaunchChoreography.playsShimmer(first, reduceMotion: false))
        XCTAssertFalse(LaunchChoreography.playsShimmer(first, reduceMotion: true), "never under Reduce Motion")
        app.launchPlayed = true   // what Welcome's launch does as it begins (`RootView`)
        let back = LaunchChoreography.arrival(launchPlayed: app.launchPlayed)
        XCTAssertEqual(back, .return)
        XCTAssertFalse(LaunchChoreography.playsShimmer(back, reduceMotion: false), "never on a return to Welcome")
    }

    /// The band clears the glyphs at both ends of its pass, its lean included.
    func testTheShimmerCrossesTheWholeWordmark() {
        let path = WordmarkShimmer<EmptyView>.travel(width: 130, height: 70)
        let lean = 70 * tan(20 * Double.pi / 180) / 2
        XCTAssertEqual(path.from + WordmarkShimmer<EmptyView>.band + lean, 0, accuracy: 1e-6, "starts just left of the wordmark")
        XCTAssertEqual(path.to - lean, 130, accuracy: 1e-6, "ends just past its right edge")
        XCTAssertEqual(WordmarkShimmer<EmptyView>.band / 130, 0.28, accuracy: 0.01)
    }
}

final class CodeRevealTests: XCTestCase {
    /// The code types itself digit by digit, 40 ms apart: each rises 4 pt over 160 ms and settles from the highlight to
    /// gold over 360 ms; the whole takes 480 ms from the first digit.
    func testTheDigitsStagger() {
        XCTAssertEqual((0..<4).map(TypedCode.offset(of:)), [0, 0.04, 0.08, 0.12])
        XCTAssertEqual(TypedCode.duration(digits: 4), 0.48, accuracy: 1e-9)
        XCTAssertEqual(TypedCode.newCodeDelay, 0.12, accuracy: 1e-9, "a new code waits for the old one to lift away")
        for index in 0..<4 {
            let before = TypedCode.digit(index, at: TypedCode.offset(of: index) - 0.001)
            XCTAssertEqual(before.opacity, 0, "digit \(index) before its slot"); XCTAssertEqual(before.drop, 4); XCTAssertEqual(before.settled, 0)
            let typed = TypedCode.digit(index, at: TypedCode.offset(of: index) + 0.16)
            XCTAssertEqual(typed.opacity, 1); XCTAssertEqual(typed.drop, 0)
            XCTAssertLessThan(typed.settled, 1, "still bright as it lands")
            XCTAssertEqual(TypedCode.digit(index, at: TypedCode.offset(of: index) + 0.36).settled, 1)
        }
        // At 60 ms digit 0 is mostly in and digit 2 not yet started.
        XCTAssertGreaterThan(TypedCode.digit(0, at: 0.06).opacity, 0.7)
        XCTAssertEqual(TypedCode.digit(2, at: 0.06).opacity, 0)
    }

    /// The colour settles from the gold highlight (#d8ba7e) to gold (#c9a86a).
    func testTheDigitsSettleFromTheHighlightToGold() {
        func rgb(_ c: Color) -> [Int] {
            let n = NSColor(c).usingColorSpace(.sRGB)!
            return [n.redComponent, n.greenComponent, n.blueComponent].map { Int(($0 * 255).rounded()) }
        }
        XCTAssertEqual(rgb(TypedCode.colour(settled: 0)), [0xd8, 0xba, 0x7e])
        XCTAssertEqual(rgb(TypedCode.colour(settled: 1)), [0xc9, 0xa8, 0x6a])
    }

    /// The code follows the pairing panel in: 280 ms after the picture's stage, 80 ms after the panel's.
    func testTheCodeFollowsThePanel() {
        XCTAssertEqual(ShareView.Stage.code - ShareView.Stage.pairing, 0.08, accuracy: 1e-9)
    }
}

final class ConnectMotionTests: XCTestCase {
    /// The ring plays once per connection: a new one draws it, the same one shown again draws it at rest, and never under
    /// Reduce Motion. It follows the row, the name and the dot in.
    func testTheRingPlaysOncePerConnection() {
        XCTAssertEqual(ConnectRing.start(trigger: 1, shownFor: 0, reduceMotion: false), .animate)
        XCTAssertEqual(ConnectRing.start(trigger: 1, shownFor: 1, reduceMotion: false), .drawn)
        XCTAssertEqual(ConnectRing.start(trigger: 2, shownFor: 1, reduceMotion: false), .animate, "a reconnect that came back")
        XCTAssertEqual(ConnectRing.start(trigger: 2, shownFor: 1, reduceMotion: true), .hidden)
        let sharer = [PairingPanel.Connect.row, PairingPanel.Connect.name, PairingPanel.Connect.dot, PairingPanel.Connect.ring]
        XCTAssertEqual(sharer, [0.06, 0.10, 0.12, 0.16], "row, name, dot, ring")
        XCTAssertEqual(PairingPanel.Connect.ringAgain, 0.08)
        XCTAssertEqual(ConnectRing.fadeOut.duration, 0.15, "the ring fades in 150 ms while the link reconnects")
    }

    /// The breathing dot: Core Animation's loop on the render server, 1 ↔ 0.35 over 1.2 s each way, the dots breathing at
    /// once sharing a phase; still once it stops.
    @MainActor
    func testTheDotBreathesOnTheRenderServer() throws {
        let a = PulseDotView(color: Theme.CanvasColors.gold), b = PulseDotView(color: Theme.CanvasColors.gold)
        a.frame = CGRect(x: 0, y: 0, width: 6, height: 6); b.frame = a.frame
        a.update(color: Theme.CanvasColors.gold, breathing: true)
        b.update(color: Theme.CanvasColors.gold, breathing: true)
        let dotA = try XCTUnwrap(a.layer?.sublayers?.first), dotB = try XCTUnwrap(b.layer?.sublayers?.first)
        let breathA = try XCTUnwrap(dotA.animation(forKey: "breath") as? CABasicAnimation)
        let breathB = try XCTUnwrap(dotB.animation(forKey: "breath") as? CABasicAnimation)
        XCTAssertEqual(breathA.duration, 1.2); XCTAssertTrue(breathA.autoreverses); XCTAssertEqual(breathA.repeatCount, .infinity)
        XCTAssertEqual(breathA.toValue as? Float, 0.35)
        XCTAssertEqual(breathA.beginTime, breathB.beginTime, accuracy: 1e-6, "the pill's dot and the chip's breathe together")
        a.update(color: Theme.CanvasColors.gold, breathing: false)
        XCTAssertNil(dotA.animation(forKey: "breath")); XCTAssertFalse(a.breathing)
        b.update(color: Theme.CanvasColors.gold, breathing: false)
        XCTAssertTrue(PulseDotView.same(NSColor(Theme.Colors.gold), Theme.CanvasColors.gold))
    }
}

final class FigureHysteresisTests: XCTestCase {
    private func snapshot(fps: Double = 60, latency: Double? = 34, bitrate: Double = 14.2, dropped: Int = 0) -> Snapshot {
        var s = Snapshot.empty
        s.captureFPS = fps; s.displayFPS = fps; s.latencyMs = latency; s.rttMs = 3; s.bitrateMbps = bitrate; s.droppedLastSecond = dropped
        return s
    }

    /// A one-unit move shows once it has held for two snapshots more (500 ms); a move of two or more at once.
    func testOneUnitMovesWaitHalfASecond() {
        var h = FigureHysteresis()
        XCTAssertEqual(h.apply(snapshot(fps: 60)).displayFPS, 60)
        XCTAssertEqual(h.apply(snapshot(fps: 59)).displayFPS, 60, "held, 0 ms")
        XCTAssertEqual(h.apply(snapshot(fps: 59)).displayFPS, 60, "held, 250 ms")
        XCTAssertEqual(h.apply(snapshot(fps: 59)).displayFPS, 59, "shown at 500 ms, never later")
        XCTAssertEqual(h.apply(snapshot(fps: 57)).displayFPS, 57, "two or more: at once")
        XCTAssertEqual(h.apply(snapshot(latency: 34)).latencyMs, 34)
        XCTAssertEqual(h.apply(snapshot(latency: 36)).latencyMs, 36)
    }

    /// 59/60 does not flicker: a value that comes back never shows the one it left for.
    func testAFigureThatFlickersHoldsStill() {
        var h = FigureHysteresis()
        _ = h.apply(snapshot(fps: 60))
        for fps in [59.0, 60, 59, 60, 59, 60, 59, 60] { XCTAssertEqual(h.apply(snapshot(fps: fps)).displayFPS, 60) }
    }

    /// The bitrate, to one decimal, with 0.3 Mbps; dropped frames always at once; a figure appearing or going at once.
    func testBitrateDroppedAndNothing() {
        var h = FigureHysteresis()
        XCTAssertEqual(h.apply(snapshot(bitrate: 14.2)).bitrateMbps, 14.2, accuracy: 1e-9)
        XCTAssertEqual(h.apply(snapshot(bitrate: 14.4)).bitrateMbps, 14.2, accuracy: 1e-9)
        XCTAssertEqual(h.apply(snapshot(bitrate: 14.5)).bitrateMbps, 14.5, accuracy: 1e-9, "0.3 shows at once")
        XCTAssertEqual(h.apply(snapshot(dropped: 1)).droppedLastSecond, 1, "dropped frames warn at once")
        XCTAssertNil(h.apply(snapshot(latency: nil)).latencyMs, "a figure going shows at once")
        XCTAssertEqual(h.apply(snapshot(latency: 35)).latencyMs, 35, "and one coming")
        XCTAssertEqual(h.apply(snapshot(fps: 0)).captureFPS, 0)
        XCTAssertEqual(h.apply(snapshot(fps: 61)).captureFPS, 61)
    }

    /// The sparkline keeps the raw series; the strip shows integers as it formats them.
    func testTheSeriesStaysRaw() {
        var h = FigureHysteresis()
        var raw = snapshot(fps: 59.6)
        raw.latencySeries = [30.4, 31.2]
        let shown = h.apply(raw)
        XCTAssertEqual(shown.latencySeries, [30.4, 31.2])
        XCTAssertEqual(shown.captureFPS, 60)
    }
}

final class SparklineMotionTests: XCTestCase {
    /// The sparkline slides left by the buckets come since the last snapshot, over the time they cover, linear, on Core
    /// Animation; the same snapshot again changes nothing; under Reduce Motion it steps.
    @MainActor
    func testTheSparklineSlidesBetweenSnapshots() throws {
        let view = SparklineView(frame: CGRect(x: 0, y: 0, width: 78, height: 18))
        view.layout()
        let buckets: [Double?] = (0..<Snapshot.bucketCount).map { $0 % 9 == 0 ? nil : 30 + Double($0 % 7) }
        view.update(buckets: buckets, newest: 1000, sliding: true)
        let slider = try XCTUnwrap(view.layer?.sublayers?.last)
        XCTAssertNil(slider.animation(forKey: "slide"), "the first snapshot is drawn at rest")
        view.update(buckets: buckets, newest: 1005, sliding: true)
        let slide = try XCTUnwrap(slider.animation(forKey: "slide") as? CABasicAnimation)
        XCTAssertEqual(slide.keyPath, "transform.translation.x")
        XCTAssertEqual(slide.duration, 0.25, accuracy: 1e-9, "five buckets of 50 ms")
        XCTAssertEqual(slide.toValue as? CGFloat ?? 0, -5 * 78 / 39, accuracy: 1e-6)
        view.update(buckets: buckets, newest: 1005, sliding: true)
        XCTAssertNotNil(slider.animation(forKey: "slide"), "the same snapshot again changes nothing")
        view.update(buckets: buckets, newest: 1010, sliding: false)
        XCTAssertNil(slider.animation(forKey: "slide"), "Reduce Motion: a step")
        XCTAssertEqual(SparklineView.slide(advance: 6, bucketWidth: 2).duration, 0.3, accuracy: 1e-9)
    }
}

final class NavigationMotionTests: XCTestCase {
    /// Ranked screens: a higher rank is forward, a lower one back, the first takes its container's way in.
    @MainActor
    func testRankedScreensKnowTheirDirection() {
        let box = NavigationBox()
        box.update(rank: 0, arrival: .back)
        XCTAssertEqual(box.direction, .back, "the list, when View came back")
        box.update(rank: 1); XCTAssertEqual(box.direction, .forward, "a Mac picked")
        box.update(rank: 1); XCTAssertEqual(box.direction, .forward, "the same screen again changes nothing")
        box.update(rank: 2); XCTAssertEqual(box.direction, .forward, "the picture")
        box.update(rank: 3); XCTAssertEqual(box.direction, .forward, "a failure")
        box.update(rank: 0); XCTAssertEqual(box.direction, .back, "Back to the list")
        box.update(rank: 1); box.update(rank: 0); XCTAssertEqual(box.direction, .back, "Back from the code")
    }

    /// Every change of screen says which way it goes: Share and View forward; Stop, a cancelled picker and Esc back.
    @MainActor
    func testEveryChangeOfScreenHasADirection() async {
        let app = AppModel(makeShare: { ShareModel(makeSource: { NeverSource() }, screenRecordingGranted: { true }) },
                           makeView: { ViewModel(startingDiscovery: false) }, terminate: {}, revealWindow: {}, hideWindows: {})
        app.startView()
        XCTAssertEqual(app.screen, .view); XCTAssertEqual(app.navigation.direction, .forward)
        app.escape()
        XCTAssertEqual(app.screen, .welcome, "Esc with nothing live: at once, in the key's own update")
        XCTAssertEqual(app.navigation.direction, .back)
        app.startShare()
        XCTAssertEqual(app.screen, .share); XCTAssertEqual(app.navigation.direction, .forward)
        app.cancelShare(animated: true)
        XCTAssertEqual(app.screen, .welcome); XCTAssertEqual(app.navigation.direction, .back)
        app.startView()
        await app.stop()
        XCTAssertEqual(app.screen, .welcome); XCTAssertEqual(app.navigation.direction, .back)
    }

    /// ⌘L shows the loop at once: it clears the time the pointer last switched it, which stages the panel's rows.
    @MainActor
    func testCommandLStagesNothing() {
        let app = AppModel(makeShare: { ShareModel(makeSource: { NeverSource() }, screenRecordingGranted: { true }) },
                           makeView: { ViewModel(startingDiscovery: false) }, terminate: {}, revealWindow: {}, hideWindows: {})
        app.startShare()
        let share = app.share!
        share.state = .capturing
        share.loopToggledAt = 5
        app.toggleLoopback()
        XCTAssertTrue(share.loopback)
        XCTAssertNil(share.loopToggledAt)
        share.state = .idle
    }

    /// The picture's stage begins when the share begins capturing, survives a resize, and ends with the capture.
    @MainActor
    func testThePicturesStageFollowsTheCapture() {
        let share = ShareModel(makeSource: { NeverSource() }, screenRecordingGranted: { true })
        XCTAssertNil(share.capturingSince)
        share.state = .capturing
        let since = share.capturingSince
        XCTAssertNotNil(since)
        share.state = .capturing
        XCTAssertEqual(share.capturingSince, since, "a new size from the same capture keeps the stage")
        share.state = .failed("stopped")
        XCTAssertNil(share.capturingSince)
        share.state = .idle
    }
}

final class ListAndNoticeMotionTests: XCTestCase {
    /// Macs listed as the screen comes in stagger from 80 ms, 40 ms apart; a later batch staggers within itself from 0,
    /// so a Mac that arrives alone rises at once, wherever it lands in the list.
    @MainActor
    func testRowsStaggerWithinTheirBatch() {
        let rows = RowStagger()
        rows.see(["a", "b", "c"], now: 1, staged: true)
        XCTAssertEqual(["a", "b", "c"].map { rows.slot(for: $0).delay }, [0.08, 0.12, 0.16])
        XCTAssertTrue(rows.slot(for: "a").animated)
        rows.see(["a", "b", "c", "d", "e", "f", "g"], now: 5, staged: true)
        XCTAssertEqual(["d", "e", "f", "g"].map { rows.slot(for: $0).delay }, [0, 0.04, 0.08, 0.12])
        rows.see(["a", "b", "c", "d", "e", "f", "g", "h"], now: 9, staged: true)
        XCTAssertEqual(rows.slot(for: "h").delay, 0, "the eighth Mac, alone: at once, not 280 ms")
        XCTAssertEqual(rows.slot(for: "h").since, 9)
        let back = RowStagger()
        back.see(["a"], now: 1, staged: false)
        XCTAssertFalse(back.slot(for: "a").animated, "the list coming back is not staggered again")
        back.see(["a", "b"], now: 2, staged: false)
        XCTAssertTrue(back.slot(for: "b").animated, "a Mac that appears later still rises in")
    }

    /// A notice stays a second once shown; new ones stagger 40 ms apart within their batch, and follow the picture's
    /// entrance while it is under way.
    func testNoticesHoldASecondAndStagger() {
        let start = NoticeStack.reconcile([], said: ["a", "b"], now: 10.01, since: 10, stageDelay: 0.32)
        XCTAssertEqual(start.map(\.text), ["a", "b"])
        XCTAssertEqual(start[0].delay, 0.31, accuracy: 1e-9, "at the picture's 320 ms")
        XCTAssertEqual(start[1].delay, 0.35, accuracy: 1e-9)
        let gone = NoticeStack.reconcile(start, said: ["b"], now: 10.5, since: 10, stageDelay: 0.32)
        XCTAssertEqual(gone.map(\.text), ["a", "b"], "held: up for less than a second")
        XCTAssertEqual(NoticeStack.reconcile(gone, said: ["b"], now: 11.02, since: 10, stageDelay: 0.32).map(\.text), ["b"])
        let later = NoticeStack.reconcile([], said: ["c", "d"], now: 40, since: 10, stageDelay: 0.32)
        XCTAssertEqual(later.map(\.delay), [0, 0.04])
    }

    /// The quality slider taps once as it reaches either end, never within the range.
    func testTheQualitySliderTapsAtItsEnds() {
        XCTAssertTrue(LoopbackPanel.reachesAnEnd(from: 3, to: 2))
        XCTAssertTrue(LoopbackPanel.reachesAnEnd(from: 59, to: 60))
        XCTAssertFalse(LoopbackPanel.reachesAnEnd(from: 20, to: 21))
        XCTAssertFalse(LoopbackPanel.reachesAnEnd(from: 60, to: 60))
    }

    /// The glint up the divider line ends 380 ms after the switch: 40 ms, then 220 ms up, then a 120 ms fade.
    func testTheDividerGlintsTimeline() {
        XCTAssertEqual(DividerGlint.end, 0.38, accuracy: 1e-9)
    }

    /// A divider label near an edge goes at its threshold and comes back 8 pt further out, so a drag resting on the
    /// threshold does not flicker.
    func testDividerLabelsHaveHysteresis() {
        XCTAssertTrue(DividerHandle.shows(true, room: 65, needs: 64))
        XCTAssertFalse(DividerHandle.shows(true, room: 64, needs: 64))
        XCTAssertFalse(DividerHandle.shows(false, room: 70, needs: 64))
        XCTAssertTrue(DividerHandle.shows(false, room: 72, needs: 64))
    }
}

final class InkMotionTests: XCTestCase {
    private let a = StrokePoint(x: 0.2, y: 0.2, pressure: 1, tMs: 0)
    private let b = StrokePoint(x: 0.6, y: 0.4, pressure: 1, tMs: 40)

    @MainActor
    private func makeCanvas(_ role: Role) -> (InkController, InkCanvasView) {
        let controller = InkController(role: role)
        let canvas = InkCanvasView(controller: controller)
        canvas.frame = NSRect(x: 0, y: 0, width: 320, height: 200)
        return (controller, canvas)
    }

    /// The peer's undo rewinds the stroke from its end: a mask on its layer draws back over 180 ms, and the stroke fades
    /// over the last 80 ms; under Reduce Motion it fades over 150 ms.
    @MainActor
    func testThePeersUndoRewinds() throws {
        let (controller, canvas) = makeCanvas(.share)
        controller.applyRemote(StrokeMessage(strokeId: 3, phase: .begin, color: .cream, baseWidth: 4, points: [a, b]))
        let layer = try XCTUnwrap((canvas.layer?.sublayers ?? []).compactMap { $0 as? CAShapeLayer }.first { $0.path != nil })
        controller.undoRemote(id: 3)
        XCTAssertTrue(controller.document.strokes.isEmpty)
        let mask = try XCTUnwrap(layer.mask as? CAShapeLayer, "a mask stroking the centre line")
        let rewind = try XCTUnwrap(mask.animation(forKey: "rewind") as? CABasicAnimation)
        XCTAssertEqual(rewind.keyPath, "strokeEnd"); XCTAssertEqual(rewind.duration, 0.18)
        XCTAssertEqual(rewind.fromValue as? Double, 1); XCTAssertEqual(rewind.toValue as? Double, 0)
        XCTAssertEqual(mask.lineCap, .round)
        XCTAssertGreaterThan(mask.lineWidth, 4 * 1.2, "wider than the stroke's widest point and its halo")
        let fade = try XCTUnwrap(layer.animation(forKey: "opacity") as? CABasicAnimation)
        XCTAssertEqual(fade.duration, 0.08, accuracy: 1e-9)

        let (reduced, reducedCanvas) = makeCanvas(.share)
        reducedCanvas.reduceMotion = true
        reduced.applyRemote(StrokeMessage(strokeId: 3, phase: .begin, color: .cream, baseWidth: 4, points: [a, b]))
        let plain = try XCTUnwrap((reducedCanvas.layer?.sublayers ?? []).compactMap { $0 as? CAShapeLayer }.first { $0.path != nil })
        reduced.undoRemote(id: 3)
        XCTAssertNil(plain.mask, "no rewind under Reduce Motion")
        XCTAssertEqual((plain.animation(forKey: "opacity") as? CABasicAnimation)?.duration, 0.15)
    }

    /// This side's ⌘Z and ⌘⌫ take effect at once; the peer's clear fades every stroke over 200 ms.
    @MainActor
    func testLocalCommandsAreInstantAndThePeersClearFades() throws {
        let (controller, canvas) = makeCanvas(.share)
        let id = controller.beginLocal(a); controller.appendLocal(id, [b]); controller.endLocal(id)
        controller.clearLocal()
        XCTAssertTrue((canvas.layer?.sublayers ?? []).compactMap { $0 as? CAShapeLayer }.allSatisfy { $0.path == nil },
                      "⌘⌫: nothing left to fade")
        controller.applyRemote(StrokeMessage(strokeId: 3, phase: .begin, color: .cream, baseWidth: 4, points: [a, b]))
        let layer = try XCTUnwrap((canvas.layer?.sublayers ?? []).compactMap { $0 as? CAShapeLayer }.first { $0.path != nil })
        controller.clearRemote()
        XCTAssertEqual((layer.animation(forKey: "opacity") as? CABasicAnimation)?.duration, 0.2)
    }
}

/// A capture source that never opens a picker or sends anything.
@MainActor
private final class NeverSource: CaptureSource {
    let frames = AsyncStream<CapturedFrame> { _ in }
    let events = AsyncStream<CaptureEvent> { _ in }
    func presentPicker(excludingWindowIDs: [CGWindowID]) {}
    func stop() async {}
}
