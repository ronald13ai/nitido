import XCTest
import AppKit
import Network
import CoreVideo
import CoreText
import IOSurface
import QuartzCore
import Darwin
import os
import NitidoTestSupport
import NitidoCore
@testable import NitidoCodec
@testable import NitidoCapture
@testable import NitidoLink
@testable import NitidoUI

// Soak tests: the share, the codec loop, the viewer's link and the decoder under load for a minute or so each, with the
// app's own models and the real hardware codec, and no window. They take long and load the machine, so they run only
// when asked for: NITIDO_SOAK=1 swift test --filter SoakTests/<test>. Each one prints its measured figures on lines
// that start with "[soak]".

private let soakRequested = ProcessInfo.processInfo.environment["NITIDO_SOAK"] == "1"

private struct TimedOut: Error {}

/// This process's memory, in MiB: resident (`proc_pidinfo`, `pti_resident_size`) and the physical footprint
/// (`proc_pid_rusage`, `ri_phys_footprint`, what Activity Monitor calls Memory). IOSurface-backed pixel buffers count in
/// both once they are touched.
private struct Memory: CustomStringConvertible {
    let resident: Double
    let footprint: Double

    static func now() -> Memory {
        var task = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let read = proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &task, size)
        var usage = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        return Memory(resident: read == size ? Double(task.pti_resident_size) / 1_048_576 : .nan,
                      footprint: status == 0 ? Double(usage.ri_phys_footprint) / 1_048_576 : .nan)
    }

    var description: String { String(format: "RSS %.1f MB, footprint %.1f MB", resident, footprint) }
}

/// A weak reference any thread may read.
private final class WeakRef: @unchecked Sendable {
    weak var value: AnyObject?
    init(_ value: AnyObject) { self.value = value }
}

/// Named weak references to what one cycle made, to check that each is gone once the cycle is over.
@MainActor
private final class Leaks {
    private var watched: [(name: String, ref: WeakRef)] = []
    func watch(_ name: String, _ object: AnyObject?) {
        guard let object else { return }
        watched.append((name, WeakRef(object)))
    }
    var alive: [String] { watched.filter { $0.ref.value != nil }.map(\.name) }
    var count: Int { watched.count }
    func forget() { watched = [] }
}

/// The pixel buffers something made, held weakly, and the IOSurfaces behind them: a pool hands the same surfaces out
/// again once their buffers are let go, so a bounded number of surfaces over thousands of frames says none was kept.
private final class BufferTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var refs: [WeakRef] = []
    private var surfaces: Set<IOSurfaceID> = []
    private var made = 0
    private var peak = 0

    func track(_ buffer: CVPixelBuffer) {
        let surface = CVPixelBufferGetIOSurface(buffer).map { IOSurfaceGetID($0.takeUnretainedValue()) }
        lock.withLock {
            refs.removeAll { $0.value == nil }
            refs.append(WeakRef(buffer)); made += 1
            peak = max(peak, refs.count)
            if let surface { surfaces.insert(surface) }
        }
    }

    /// The most buffers alive at once, counted each time one was made, that one included.
    var peakAlive: Int { lock.withLock { peak } }

    /// How many of the buffers tracked so far something still holds.
    func alive() -> Int {
        lock.withLock {
            refs.removeAll { $0.value == nil }
            return refs.count
        }
    }

    var tracked: Int { lock.withLock { made } }
    var distinctSurfaces: Int { lock.withLock { surfaces.count } }
}

/// The attachment each frame carries its capture time in, so a frame the view holds says which capture it was.
private var captureTimeKey: CFString { "ai.ronar.nitido.soak.captureHostTimeNs" as CFString }

/// A long page of text drawn once, which every frame shows scrolled six pixels further, as a document scrolled with the
/// trackpad at 360 pixels a second: every frame differs from the one before all over, the hard case for the encoder
/// short of noise. Frames come from a pool per size, as ScreenCaptureKit's do, each stamped with its capture time.
private final class ScrollingPage: @unchecked Sendable {
    /// The most buffers a pool may hand out at once; more would mean the share keeps captured frames.
    static let poolLimit = 64
    let width: Int
    private let rows: Int
    private let travel: Int
    private let rowBytes: Int
    private let pattern: UnsafeMutableRawPointer
    private let lock = NSLock()
    private var pools: [Int: CVPixelBufferPool] = [:]

    init(width: Int, height: Int, travel: Int = 2400) throws {
        self.width = width; self.travel = travel
        rows = height + travel; rowBytes = width * 4
        pattern = .allocate(byteCount: rowBytes * rows, alignment: 64)
        guard let context = CGContext(data: pattern, width: width, height: rows, bitsPerComponent: 8, bytesPerRow: rowBytes,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { pattern.deallocate(); throw XCTSkip("CGContext over the page failed") }
        context.setFillColor(CGColor(red: 0.98, green: 0.97, blue: 0.94, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: rows))
        let font = CTFontCreateWithName("Menlo" as CFString, 13, nil)
        let words = ["let", "frame", "encoder", "decoder", "viewer", "keyframe", "backlog", "0x6a", "return", "guard",
                     "await", "Nitido", "{", "}", "(", ")", "=", "+", "1756", "2692", "sharer", "divider", "pacer"]
        let inks = [CGColor(red: 0.08, green: 0.07, blue: 0.06, alpha: 1), CGColor(red: 0.55, green: 0.35, blue: 0.05, alpha: 1),
                    CGColor(red: 0.10, green: 0.30, blue: 0.55, alpha: 1)]
        var line = 0
        for y in stride(from: 6, to: rows, by: 17) {
            if line % 23 == 0 {
                context.setFillColor(CGColor(red: 0.85, green: 0.78, blue: 0.55, alpha: 1))
                context.fill(CGRect(x: 0, y: y - 4, width: width, height: 17))
            }
            var text = "\(line)  "
            var i = line
            while text.count < 40 + (line * 37) % 300 { text += words[(i * 7 + line) % words.count] + " "; i += 1 }
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): inks[line % inks.count],
            ]
            context.textPosition = CGPoint(x: 10, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
            line += 1
        }
    }

    deinit { pattern.deallocate() }

    /// Frame `index` at `w` × `h`, stamped `captureNs`, or nil when its pool would have to hand out more than
    /// `poolLimit` buffers at once.
    func frame(index: Int, width w: Int, height h: Int, captureNs: UInt64) -> CVPixelBuffer? {
        precondition(w <= width && h <= rows - travel, "the page is \(width) × \(rows - travel)")
        let pool = pool(w, h)
        var made: CVPixelBuffer?
        let limit = [kCVPixelBufferPoolAllocationThresholdKey: Self.poolLimit] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, limit, &made) == kCVReturnSuccess,
              let buffer = made else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let offset = (index * 6) % travel
        for y in 0..<h { memcpy(base + y * stride, pattern + (offset + y) * rowBytes, w * 4) }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        CVBufferSetAttachment(buffer, captureTimeKey, NSNumber(value: captureNs), .shouldNotPropagate)
        return buffer
    }

    /// The pool for `w` × `h`. Only the current size's pool is kept, as a stream restarted at a new size gets a new one:
    /// a pool keeps its minimum of buffers for good, which would count against the share's memory.
    private func pool(_ w: Int, _ h: Int) -> CVPixelBufferPool {
        lock.withLock {
            if let pool = pools[w * 100_000 + h] { return pool }
            pools.removeAll()
            let attributes: [CFString: Any] = [
                kCVPixelBufferWidthKey: w, kCVPixelBufferHeightKey: h,
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary, kCVPixelBufferMetalCompatibilityKey: true,
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary, attributes as CFDictionary, &pool)
            pools[w * 100_000 + h] = pool!
            return pool!
        }
    }
}

/// What a soak source hands the share, reachable from any thread: its streams' inputs and the frames its stream let go.
private struct SourceOutputs: Sendable {
    let frames: AsyncStream<CapturedFrame>.Continuation
    let events: AsyncStream<CaptureEvent>.Continuation
    let dropped: OSAllocatedUnfairLock<Int>
    /// Every frame the stream let go, never reset.
    let droppedTotal = OSAllocatedUnfairLock(initialState: 0)

    /// Hands the share `frame`; a frame it has not taken yet is let go and counted.
    func yield(_ frame: CapturedFrame) {
        if case .dropped = frames.yield(frame) { dropped.withLock { $0 += 1 }; droppedTotal.withLock { $0 += 1 } }
    }
}

/// Stands in for `CaptureSession` as the share sees it: the frame stream keeps only the newest frame, and a frame the
/// share has not taken yet when the next one comes is let go and counted (`takeDroppedFrames`), as there.
@MainActor
private final class SoakSource: CaptureSource {
    let frames: AsyncStream<CapturedFrame>
    let events: AsyncStream<CaptureEvent>
    nonisolated let outputs: SourceOutputs

    init() {
        let (frames, frameOut) = AsyncStream<CapturedFrame>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let (events, eventOut) = AsyncStream<CaptureEvent>.makeStream(bufferingPolicy: .bufferingNewest(8))
        self.frames = frames; self.events = events
        outputs = SourceOutputs(frames: frameOut, events: eventOut, dropped: OSAllocatedUnfairLock(initialState: 0))
    }

    func presentPicker(excludingWindowIDs: [CGWindowID]) {}
    func stop() async {}
    func takeDroppedFrames() -> Int { outputs.dropped.withLock { count in defer { count = 0 }; return count } }

    /// Hands the share one frame now, from the main actor.
    func emit(_ buffer: CVPixelBuffer, width: Int, height: Int) {
        let frame = CapturedFrame(pixelBuffer: buffer, captureHostTimeNs: UInt64(CACurrentMediaTime() * 1e9),
                                  contentRect: CGRect(x: 0, y: 0, width: width / 2, height: height / 2), scale: 2)
        outputs.yield(frame)
    }
}

/// Makes a frame of `page` 60 times a second on its own queue, as ScreenCaptureKit does, and hands it to `deliver`. A
/// new size is announced (`announce`) before its first frame, as a resized window is. For every frame it records how
/// many of the frames it made before are still held: ScreenCaptureKit, with the queue depth of 3 `CaptureSession`
/// asks for, has no surface left to draw a new frame into once the app holds three.
private final class Feeder: @unchecked Sendable {
    private let page: ScrollingPage
    private let deliver: @Sendable (CapturedFrame) -> Void
    private let announce: @Sendable (Int, Int) -> Void
    private let queue = DispatchQueue(label: "ai.ronar.nitido.soak.feeder", qos: .userInteractive)
    private let lock = NSLock()
    // Guarded by `lock`.
    private var timer: DispatchSourceTimer?
    private var wanted: (width: Int, height: Int)
    private var made = 0
    private var exhausted = 0
    private var heldAtFrame: [Int: Int] = [:]
    // Only touched on `queue`.
    private var current: (width: Int, height: Int)?
    private var index = 0
    let raws = BufferTracker()

    init(page: ScrollingPage, width: Int, height: Int, deliver: @escaping @Sendable (CapturedFrame) -> Void,
         announce: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) {
        self.page = page; self.deliver = deliver; self.announce = announce
        wanted = (width, height)
    }

    /// Feeds the share's source: frames through its stream, sizes as `.started`.
    convenience init(page: ScrollingPage, width: Int, height: Int, source outputs: SourceOutputs) {
        self.init(page: page, width: width, height: height, deliver: { frame in outputs.yield(frame) }, announce: { w, h in outputs.events.yield(.started(pixelWidth: w, pixelHeight: h, scale: 2)) })
    }

    func start(fps: Double = 60) {
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now(), repeating: 1 / fps, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.tick() }
        lock.withLock { self.timer = timer }
        timer.resume()
    }

    /// Stops, and returns once no frame is being made.
    func stop() {
        lock.withLock { timer }?.cancel()
        queue.sync {}
    }

    func resize(width: Int, height: Int) { lock.withLock { wanted = (width, height) } }

    var framesMade: Int { lock.withLock { made } }
    /// Frames the pool could not make: `ScrollingPage.poolLimit` buffers were still held.
    var poolExhausted: Int { lock.withLock { exhausted } }
    /// For each count of earlier frames still held, how many frames found that many when they were made.
    var heldHistogram: [Int: Int] { lock.withLock { heldAtFrame } }

    private func tick() {
        let size = lock.withLock { wanted }
        if current?.width != size.width || current?.height != size.height {
            current = size
            announce(size.width, size.height)
        }
        let held = raws.alive()
        let ns = UInt64(CACurrentMediaTime() * 1e9)
        guard let buffer = page.frame(index: index, width: size.width, height: size.height, captureNs: ns) else {
            lock.withLock { exhausted += 1 }
            return
        }
        index += 1
        raws.track(buffer)
        lock.withLock { made += 1; heldAtFrame[held, default: 0] += 1 }
        deliver(CapturedFrame(pixelBuffer: buffer, captureHostTimeNs: ns,
                              contentRect: CGRect(x: 0, y: 0, width: size.width / 2, height: size.height / 2), scale: 2))
    }
}

/// The sharer's clock for counting wrong codes (`ShareModel.handshakeClock`), moved on by hand.
@MainActor
private final class SharerClock { var now: CFTimeInterval = 1_000 }

/// Counts the decoded frames that reach the viewer's sink: with no view each one is reported as hidden.
@MainActor
private final class ShownCounter {
    var count = 0
    init(_ sink: FrameSink) {
        let report = sink.onDropped
        sink.onDropped = { [unowned self] drop in
            report?(drop)
            if drop == .hidden { count += 1 }
        }
    }
}

/// The video frames a plain viewer link received, in order, and when each came (`CACurrentMediaTime`).
@MainActor
private final class ReceivedFrames {
    var frames: [(seq: UInt32, isKey: Bool, bytes: Int, at: CFTimeInterval)] = []
    var keyframes: [(bytes: Int, at: CFTimeInterval)] { frames.filter(\.isKey).map { ($0.bytes, $0.at) } }
}

/// The viewer's link session, read by reflection: `ViewModel.link` is private, and a soak test does not widen the app's
/// surface for itself. The test fails, rather than passes blind, if the property is no longer there.
@MainActor
private func linkSession(of viewer: ViewModel, file: StaticString = #filePath, line: UInt = #line) -> LinkSession? {
    let children = Mirror(reflecting: viewer).children
    guard let child = children.first(where: { $0.label == "_link" || $0.label == "link" }) else {
        XCTFail("ViewModel keeps no link any more: \(children.compactMap(\.label))", file: file, line: line)
        return nil
    }
    return child.value as? LinkSession
}

/// The session's current link, read by reflection like `linkSession(of:)`.
private func currentLink(of session: LinkSession?, file: StaticString = #filePath, line: UInt = #line) -> NitidoLink.Link? {
    guard let session else { return nil }
    let children = Mirror(reflecting: session).children
    guard let child = children.first(where: { $0.label == "_current" }) else {
        XCTFail("LinkSession keeps no current link any more: \(children.compactMap(\.label))", file: file, line: line)
        return nil
    }
    return child.value as? NitidoLink.Link
}

final class SoakTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(soakRequested, "soak tests run only with NITIDO_SOAK=1")
    }

    @MainActor
    private func drain() async { for _ in 0..<50 { await Task.yield() } }

    @MainActor
    private func waitUntil(_ what: String, timeout: Double = 10, _ condition: () -> Bool) async throws {
        let deadline = CACurrentMediaTime() + timeout
        while !condition() {
            guard CACurrentMediaTime() < deadline else { XCTFail("timed out waiting until \(what)"); throw TimedOut() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor
    private func peer(for share: ShareModel) -> Peer {
        Peer(id: "loopback", name: share.name, keyName: share.name,
             endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: share.listeningPort!)!))
    }

    private func report(_ line: String) { print("[soak] \(line)") }

    // MARK: 1. The codec loop for a minute

    /// The codec loop at 2692 × 1756 for 60 s, fed a scrolling page at 60 fps from the capture's own kind of queue, with
    /// the window resized every 10 s and the quality slider moved every 5 s (2 to 60 Mbps). The loop never falls
    /// behind, never shows a failure, its memory grows by less than 60 MB between second 10 and second 60, and once
    /// settled it drops fewer than 2 frames a second.
    @MainActor
    func testTheCodecLoopRunsAMinuteAt2692x1756WithResizesAndSliderMoves() async throws {
        let page = try ScrollingPage(width: 2692, height: 1756)
        let source = SoakSource()
        let share = ShareModel(makeSource: { source }, screenRecordingGranted: { true })
        // Outside any window the view keeps the frame it is handed, with its comparison, as the Share window's does
        // (`FramePacer.held`), and reports each frame as a pause: the dropped figure counts the codec loop alone.
        let view = VideoView(frame: NSRect(x: 0, y: 0, width: 1346, height: 878))
        share.sink.view = view
        share.start(excludingWindowIDs: [])
        await drain()
        source.outputs.events.yield(.started(pixelWidth: 2692, pixelHeight: 1756, scale: 2))
        try await waitUntil("the share captures") { share.state == .capturing }
        share.qualityMbps = 20
        share.loopback = true
        let feeder = Feeder(page: page, width: 2692, height: 1756, source: source.outputs)
        let mark = LogMark()
        let start = CACurrentMediaTime(), startDate = Date()
        let memoryAtStart = Memory.now()
        feeder.start()

        let sizes = [(2692, 1756), (2400, 1560), (2692, 1756), (1920, 1252), (2692, 1756), (2560, 1600)]
        let qualities: [Double] = [20, 45, 8, 60, 2, 30, 12, 50, 5, 25, 40, 15]
        var resizes = 0, moves = 0, second = 0
        var droppedThen = share.droppedFramesTotal, framesThen = 0, captureDropsThen = 0
        var dropsPerSecond: [Int] = [], framesPerSecond: [Int] = [], captureDropsPerSecond: [Int] = []
        var residentPerSecond: [Double] = [], footprintPerSecond: [Double] = []
        var memoryAt10: Memory?
        var peak = memoryAtStart.resident
        var failures: [String] = [], notices: Set<String> = []
        var comparisonLag: [Int: Int] = [:]
        var nextLagSample = 0.0
        var maxEncodeFailures = 0, maxDecodeFailures = 0
        var events: [(at: Double, what: String)] = []
        while true {
            try await Task.sleep(for: .milliseconds(50))
            let t = CACurrentMediaTime() - start
            if Int(t) > second {
                second = Int(t)
                dropsPerSecond.append(share.droppedFramesTotal - droppedThen); droppedThen = share.droppedFramesTotal
                framesPerSecond.append(feeder.framesMade - framesThen); framesThen = feeder.framesMade
                let captureDrops = source.outputs.droppedTotal.withLock { $0 }
                captureDropsPerSecond.append(captureDrops - captureDropsThen); captureDropsThen = captureDrops
                let memory = Memory.now()
                residentPerSecond.append(memory.resident); footprintPerSecond.append(memory.footprint)
                peak = max(peak, memory.resident)
            }
            if t >= 60 { break }
            if memoryAt10 == nil, t >= 10 { memoryAt10 = Memory.now() }
            if t >= Double(10 * (resizes + 1)) {
                resizes += 1
                let (w, h) = sizes[resizes % sizes.count]
                feeder.resize(width: w, height: h)
                events.append((t, "resize to \(w)×\(h)"))
            }
            if t >= Double(5 * (moves + 1)) {
                moves += 1
                share.qualityMbps = qualities[moves % qualities.count]
                events.append((t, "quality \(Int(share.qualityMbps)) Mbps"))
            }
            if share.state != .capturing { failures.append(String(format: "%.1f s: %@", t, "\(share.state)")) }
            if let notice = share.codecNotice { notices.insert(notice) }
            if let notice = share.renderFailure { notices.insert(notice) }
            maxEncodeFailures = max(maxEncodeFailures, share.encodeFailures)
            maxDecodeFailures = max(maxDecodeFailures, share.decodeFailures)
            // Which capture the raw half of the comparison on screen is, against the decoded half's, in frames.
            if t >= nextLagSample, let held = view.pacer.held, let raw = held.compareWith,
               let rawNs = (CVBufferCopyAttachment(raw, captureTimeKey, nil) as? NSNumber)?.uint64Value {
                nextLagSample = t + 0.25
                let lag = Int(((Double(rawNs) - Double(held.captureHostTimeNs)) / 16_666_667).rounded())
                comparisonLag[lag, default: 0] += 1
            }
        }
        let memoryAt60 = Memory.now()
        let snapshot = share.snapshot
        feeder.stop()
        let made = feeder.framesMade

        let shareLog = try mark.entries("share").map(\.composedMessage)
        let codecEntries = try mark.entries("codec")
        let codecLog = codecEntries.map(\.composedMessage)
        let fellBehind = shareLog.filter { $0.contains("fell behind") }
        let vtDrops = codecEntries.filter { $0.composedMessage.contains("VideoToolbox dropped") }
            .map { String(format: "%.2f s: ", $0.date.timeIntervalSince(startDate)) + $0.composedMessage }
        let codecErrors = codecLog.filter { $0.contains("encode callback") || $0.contains("could not decode") || $0.contains("rejected") }
        let settled = Array(dropsPerSecond.dropFirst(3))
        let held = feeder.heldHistogram.sorted { $0.key < $1.key }
        let starved = feeder.heldHistogram.filter { $0.key >= 3 }.values.reduce(0, +)

        report("codec loop: \(made) frames made in 60 s, \(share.codecLabel), \(resizes) resizes, \(moves) slider moves")
        report("codec loop: memory at 0 s \(memoryAtStart), at 10 s \(memoryAt10.map { "\($0)" } ?? "none"), at 60 s \(memoryAt60), peak RSS \(String(format: "%.1f", peak)) MB")
        report("codec loop: frames made per second \(framesPerSecond)")
        report("codec loop: frames the capture stream let go per second \(captureDropsPerSecond)")
        report("codec loop: RSS per second \(residentPerSecond.map { String(format: "%.0f", $0) })")
        report("codec loop: footprint per second \(footprintPerSecond.map { String(format: "%.0f", $0) })")
        report("codec loop: dropped per second \(dropsPerSecond) (total \(share.droppedFramesTotal)); last strip figure \(snapshot.droppedLastSecond)")
        report("codec loop: codec p50 \(share.codecMs.map { String(format: "%.1f ms", $0) } ?? "none"), last strip bitrate \(String(format: "%.1f", snapshot.bitrateMbps)) Mbps")
        report("codec loop: earlier frames still held when a frame was made \(held), \(starved) of \(made) found 3 or more")
        report("codec loop: raw half of the comparison minus the decoded half, in frames \(comparisonLag.sorted { $0.key < $1.key })")
        report("codec loop: capture surfaces used \(feeder.raws.distinctSurfaces), pool exhausted \(feeder.poolExhausted) times")
        report("codec loop: fell behind \(fellBehind.count), VideoToolbox drop lines \(vtDrops.count), codec error lines \(codecErrors.count), max encode failures in a row \(maxEncodeFailures), max decode failures in a row \(maxDecodeFailures)")
        report("codec loop: events \(events.map { String(format: "%.1f s %@", $0.at, $0.what) })")
        for line in (vtDrops + codecErrors).prefix(10) { report("codec loop log: \(line)") }
        if !failures.isEmpty { report("codec loop: states \(failures.prefix(5))") }
        if !notices.isEmpty { report("codec loop: notices \(notices)") }

        XCTAssertEqual(failures, [], "the share never leaves capturing: no failure card")
        XCTAssertEqual(notices, [], "no codec notice or render failure over the picture")
        XCTAssertEqual(fellBehind, [], "the loop's decoder never falls behind")
        XCTAssertEqual(feeder.poolExhausted, 0, "the share never holds \(ScrollingPage.poolLimit) captured frames")
        let growth = memoryAt60.resident - (memoryAt10?.resident ?? memoryAt60.resident)
        XCTAssertLessThan(growth, 60, "RSS grows by \(growth) MB between second 10 and second 60")
        XCTAssertLessThan(settled.max() ?? 0, 2, "fewer than 2 dropped frames a second once settled: \(settled)")
        await share.stop()
    }

    // MARK: 2. Viewers that come and go

    /// Thirty cycles of a viewer pairing over 127.0.0.1, dropping without a bye and reconnecting by itself, then leaving,
    /// with wrong codes in every other cycle (every third of them twice in a row, one attempt). The sharer changes its code
    /// exactly when three attempts have failed, every viewer, session, link, decoder and ink controller of a cycle is
    /// gone once the cycle is over, the listener can be reached after every cycle, and memory grows by under 30 MB.
    @MainActor
    func testThirtyViewerCyclesWithWrongCodesLeaveNothingBehind() async throws {
        let page = try ScrollingPage(width: 1280, height: 800, travel: 600)
        let source = SoakSource()
        let share = ShareModel(makeSource: { source }, screenRecordingGranted: { true })
        share.start(excludingWindowIDs: [])
        await drain()
        source.outputs.events.yield(.started(pixelWidth: 1280, pixelHeight: 800, scale: 2))
        try await waitUntil("the sharer listens") { share.listeningPort != nil }
        let clock = SharerClock()
        share.handshakeClock = { clock.now }
        var frameIndex = 0
        func emitFrame() {
            guard let buffer = page.frame(index: frameIndex, width: 1280, height: 800,
                                          captureNs: UInt64(CACurrentMediaTime() * 1e9)) else { return }
            frameIndex += 1
            source.emit(buffer, width: 1280, height: 800)
        }
        emitFrame()
        await drain()
        // One viewer before counting, so what the first connection loads once (TLS, the decoder) is not counted.
        do {
            let warm = ViewModel(startingDiscovery: false)
            let shown = ShownCounter(warm.sink)
            warm.select(peer(for: share)); warm.code = share.code; warm.connect()
            try await waitUntil("the warm-up viewer shows the picture") { warm.state == .connected && shown.count >= 1 }
            warm.disconnect()
            try await waitUntil("the sharer lets the warm-up viewer go") { share.link == nil && !share.isSending }
        }
        try await Task.sleep(for: .seconds(1.5))

        let leaks = Leaks()
        let baseline = Memory.now()
        let tasksBefore = share.tasks.count
        var attempts = 0, rotations = 0, wrongCodes = 0, watched = 0
        var leaked: [String] = []
        var memoryByCycle: [Double] = []
        var cycleSeconds: [Double] = []
        for cycle in 1...30 {
            let cycleStart = CACurrentMediaTime()
            do {
                let viewer = ViewModel(startingDiscovery: false)
                let shown = ShownCounter(viewer.sink)
                leaks.watch("cycle \(cycle) ViewModel", viewer)
                leaks.watch("cycle \(cycle) InkController", viewer.ink)

                if cycle % 2 == 0 {
                    // A wrong code, once, or twice within the sharer's second (one attempt), on its own clock. Twice only
                    // for the second attempt of three: the third rotates the code at its first failure, and a second
                    // try would dial the retired listener.
                    let failures = cycle % 6 == 4 ? 2 : 1
                    let before = share.code, listener = share.advertiser
                    clock.now += 3.5
                    viewer.select(peer(for: share))
                    viewer.code = String(format: "%04d", (Int(before)! + 1 + cycle) % 10_000)
                    for n in 1...failures {
                        viewer.connect()
                        let session = linkSession(of: viewer)
                        leaks.watch("cycle \(cycle) wrong-code LinkSession \(n)", session)
                        leaks.watch("cycle \(cycle) wrong-code Link \(n)", currentLink(of: session))
                        try await waitUntil("cycle \(cycle): wrong code \(n) goes back to the code") { viewer.wrongCodeCount == n }
                    }
                    wrongCodes += failures
                    attempts += 1
                    if attempts == HandshakeFailures.rotateAfter {
                        try await waitUntil("cycle \(cycle): the third attempt rotates the code") { share.code != before }
                        try await waitUntil("cycle \(cycle): the new listener is ready") { share.listeningPort != nil }
                        XCTAssertEqual(share.wrongCodeAttempts, 0, "cycle \(cycle): counting starts again")
                        leaks.watch("cycle \(cycle) retired Advertiser", listener)
                        attempts = 0; rotations += 1
                    } else {
                        try await waitUntil("cycle \(cycle): the sharer counts attempt \(attempts)") {
                            share.wrongCodeAttempts == attempts && share.unpairedCount == 0
                        }
                        try await Task.sleep(for: .milliseconds(200))
                        XCTAssertEqual(share.code, before, "cycle \(cycle): no rotation before three attempts")
                        XCTAssertEqual(share.wrongCodeAttempts, attempts, "cycle \(cycle): \(failures) failures are one attempt")
                    }
                }

                // The right code.
                viewer.select(peer(for: share))
                viewer.code = share.code
                viewer.connect()
                let session = linkSession(of: viewer)
                leaks.watch("cycle \(cycle) LinkSession", session)
                try await waitUntil("cycle \(cycle): the viewer shows the picture") {
                    viewer.state == .connected && share.isSending && shown.count >= 1
                }
                leaks.watch("cycle \(cycle) viewer Link", currentLink(of: session))
                leaks.watch("cycle \(cycle) sharer Link", share.link)
                leaks.watch("cycle \(cycle) VideoDecoder", viewer.decoder)
                let before = shown.count
                for _ in 0..<3 { emitFrame(); try await Task.sleep(for: .milliseconds(30)) }
                try await waitUntil("cycle \(cycle): new frames reach the viewer") { shown.count > before }

                // The link drops without a bye from the sharer's side: the viewer reconnects by itself.
                share.link?.abort()
                try await waitUntil("cycle \(cycle): the viewer reconnects") {
                    viewer.connectionCount == 2 && viewer.state == .connected && share.isSending
                }
                leaks.watch("cycle \(cycle) viewer Link after the reconnect", currentLink(of: session))
                leaks.watch("cycle \(cycle) sharer Link after the reconnect", share.link)
                let again = shown.count
                emitFrame()
                try await waitUntil("cycle \(cycle): a frame reaches the viewer after the reconnect") { shown.count > again }
                leaks.watch("cycle \(cycle) VideoDecoder after the reconnect", viewer.decoder)

                viewer.disconnect()
                try await waitUntil("cycle \(cycle): the sharer lets the viewer go") {
                    share.link == nil && !share.isSending && share.viewerName == nil
                }
            }
            watched += leaks.count
            let deadline = CACurrentMediaTime() + 6
            while !leaks.alive.isEmpty, CACurrentMediaTime() < deadline { try await Task.sleep(for: .milliseconds(50)) }
            if !leaks.alive.isEmpty {
                leaked += leaks.alive
                XCTFail("cycle \(cycle) left behind: \(leaks.alive)")
            }
            leaks.forget()
            XCTAssertEqual(share.unpairedCount, 0, "cycle \(cycle): no connection is left proving the code")
            XCTAssertNotNil(share.listeningPort, "cycle \(cycle): the listener is up")
            memoryByCycle.append(Memory.now().resident)
            cycleSeconds.append(CACurrentMediaTime() - cycleStart)
        }

        // The listener is still reachable, and the right code still pairs.
        let hello = Hello(protocolVersion: protocolVersion, role: .view, name: "Last", pixelWidth: 0, pixelHeight: 0, scale: 2)
        let last = NitidoLink.Link.connect(to: peer(for: share).endpoint, code: share.code, sharerName: share.name, hello: hello)
        try await waitUntil("a last viewer pairs") { last.state == .ready && share.isSending }
        last.close()
        try await waitUntil("the sharer lets it go") { share.link == nil }
        try await Task.sleep(for: .seconds(1))
        let final = Memory.now()

        report("viewer cycles: 30 cycles, \(watched) objects watched, \(leaked.count) left behind \(leaked)")
        report("viewer cycles: \(wrongCodes) wrong codes in 15 attempts, \(rotations) rotations, \(share.connectionCount) connections")
        report("viewer cycles: memory before \(baseline), after \(final), growth \(String(format: "%.1f", final.resident - baseline.resident)) MB")
        report("viewer cycles: RSS after each cycle \(memoryByCycle.map { String(format: "%.0f", $0) })")
        report("viewer cycles: seconds per cycle \(cycleSeconds.map { String(format: "%.1f", $0) })")
        report("viewer cycles: the share's task list held \(tasksBefore) tasks before the cycles and \(share.tasks.count) after \(rotations) rotations")

        XCTAssertEqual(rotations, 5, "15 attempts rotate the code five times")
        XCTAssertEqual(leaked, [], "nothing a cycle made outlives it")
        XCTAssertLessThan(final.resident - baseline.resident, 30, "RSS grows by under 30 MB over 30 cycles")
        await share.stop()
    }

    // MARK: 3. A keyframe request storm

    /// A viewer that asks for a keyframe 200 times in 2 s while the share sends a scrolling page at 60 fps, with a send
    /// backlog of a second and a half's worth put on the link for part of it (`addBacklogForTesting`), so the skip and
    /// its drain ask for keyframes too: at most five keyframes go out in any 2 s, the encoder never fails ten frames in
    /// a row, and the real backlog stays bounded.
    @MainActor
    func testAKeyframeRequestStormForcesAtMostFiveKeyframesInTwoSeconds() async throws {
        let page = try ScrollingPage(width: 2692, height: 1756)
        let source = SoakSource()
        let share = ShareModel(makeSource: { source }, screenRecordingGranted: { true })
        share.start(excludingWindowIDs: [])
        await drain()
        source.outputs.events.yield(.started(pixelWidth: 2692, pixelHeight: 1756, scale: 2))
        try await waitUntil("the sharer listens") { share.listeningPort != nil }
        let feeder = Feeder(page: page, width: 2692, height: 1756, source: source.outputs)
        feeder.start()
        let hello = Hello(protocolVersion: protocolVersion, role: .view, name: "Storm", pixelWidth: 0, pixelHeight: 0, scale: 2)
        let viewer = NitidoLink.Link.connect(to: peer(for: share).endpoint, code: share.code, sharerName: share.name, hello: hello)
        let received = ReceivedFrames()
        let reader = Task { @MainActor in
            for await m in viewer.messages {
                if case .videoFrame(let f) = m { received.frames.append((f.seq, f.isKey, f.data.count, CACurrentMediaTime())) }
            }
        }
        defer { reader.cancel() }
        try await waitUntil("the viewer gets the keyframe it paired with") { !received.keyframes.isEmpty }
        let link = try XCTUnwrap(share.link)
        try await Task.sleep(for: .seconds(1.5))   // past the half-second limit, the encoder at its pace

        let mark = LogMark()
        let droppedBefore = share.droppedFramesTotal
        let framesBefore = received.frames.count
        let stormStart = CACurrentMediaTime()
        let clock = ContinuousClock()
        let t0 = clock.now
        let injected = share.currentBitrate / 8 * 3 / 2
        var injectedNow = 0, worstBacklog = 0, maxEncodeFailures = 0
        var states: [String] = []
        for i in 0..<200 {
            viewer.send(.keyframeRequest)
            if i == 50 { link.addBacklogForTesting(injected); injectedNow = injected }
            if i == 110 { link.addBacklogForTesting(-injected); injectedNow = 0 }
            worstBacklog = max(worstBacklog, link.backlogFiguresForTesting.total - injectedNow)
            maxEncodeFailures = max(maxEncodeFailures, share.encodeFailures)
            if share.state != .capturing { states.append("\(share.state)") }
            try await Task.sleep(until: t0 + .milliseconds(10 * (i + 1)), clock: clock)
        }
        let stormEnd = CACurrentMediaTime()
        var tailBacklog = 0
        let tailEnd = CACurrentMediaTime() + 1.0
        while CACurrentMediaTime() < tailEnd {
            try await Task.sleep(for: .milliseconds(20))
            tailBacklog = max(tailBacklog, link.backlogFiguresForTesting.total)
            maxEncodeFailures = max(maxEncodeFailures, share.encodeFailures)
            if share.state != .capturing { states.append("\(share.state)") }
        }
        let finalBacklog = link.backlogFiguresForTesting.total
        feeder.stop()

        let keys = received.keyframes.filter { $0.at >= stormStart && $0.at <= stormEnd + 1.0 }
        let times = keys.map { $0.at - stormStart }
        var worstWindow = 0
        for start in times { worstWindow = max(worstWindow, times.filter { $0 >= start && $0 <= start + 2.0 }.count) }
        let inStorm = times.filter { $0 <= stormEnd - stormStart }.count
        let gaps = zip(times, times.dropFirst()).map { $1 - $0 }
        let shareLog = try mark.entries("share").map(\.composedMessage)
        let codecLog = try mark.entries("codec").map(\.composedMessage)
        let keepsFailing = shareLog.filter { $0.contains("failed 10 frames in a row") }
        let vtDrops = codecLog.filter { $0.contains("VideoToolbox dropped") }
        let skips = shareLog.filter { $0.contains("skipping frames until a keyframe") }
        let drains = shareLog.filter { $0.contains("drained after") }
        let frames = received.frames.count - framesBefore

        report(String(format: "keyframe storm: 200 asks in %.2f s; %d keyframes in the storm, %d in any 2 s at most",
                      stormEnd - stormStart, inStorm, worstWindow))
        report("keyframe storm: keyframes at \(times.map { String(format: "%.3f", $0) }) s, sizes \(keys.map(\.bytes)) bytes, gaps \(gaps.map { String(format: "%.3f", $0) })")
        report("keyframe storm: \(frames) frames reached the viewer, \(share.droppedFramesTotal - droppedBefore) dropped on the sharer, \(skips.count) skips, \(drains.count) drains")
        report("keyframe storm: real backlog at most \(worstBacklog) bytes in the storm, \(tailBacklog) after, \(finalBacklog) at the end; injected \(injected)")
        report("keyframe storm: max encode failures in a row \(maxEncodeFailures), VideoToolbox drop lines \(vtDrops.count), keeps-failing lines \(keepsFailing.count), states \(states.prefix(3))")
        for line in (vtDrops + skips + drains).prefix(12) { report("keyframe storm log: \(line)") }

        XCTAssertLessThanOrEqual(worstWindow, 5, "at most five keyframes in any 2 s: \(times)")
        XCTAssertGreaterThanOrEqual(inStorm, 3, "the storm is answered: \(times)")
        for gap in gaps { XCTAssertGreaterThan(gap, 0.4, "keyframes half a second apart: \(times)") }
        XCTAssertEqual(states, [], "the share keeps capturing: no \"Video encoding keeps failing\"")
        XCTAssertEqual(keepsFailing, [])
        XCTAssertLessThan(maxEncodeFailures, 10)
        XCTAssertLessThan(worstBacklog, share.currentBitrate / 8, "the real backlog stays under a second's worth")
        XCTAssertLessThan(finalBacklog, 1_000_000, "the backlog drains once the storm is over")
        viewer.close()
        await share.stop()
    }

    // MARK: 4. The decoder under bursts

    /// 2000 frames of a scrolling page at 2692 × 1756 from the hardware encoder, handed to the decoder ten at a time from
    /// another thread, while the main actor stalls for 200 ms every second, through the outbox the viewer and the codec
    /// loop use (`DecoderOutbox`). The decoder's queue and the outbox stay bounded, what reaches the main actor comes in
    /// order, and no decoded pixel buffer outlives the frames that held it.
    @MainActor
    func testTheDecoderTakesTwoThousandFramesInBurstsOfTenWhileTheMainActorStalls() async throws {
        let width = 2692, height = 1756, total = 2000
        let page = try ScrollingPage(width: width, height: height)
        let encoder = try VideoEncoder(width: width, height: height, preferred: .hevc, bitsPerSecond: 30_000_000)
        let pictures = BufferTracker()
        let collector = OutboxCollector()
        let batches = Batches()
        let bursts = Bursts(total: total)
        bursts.requestKeyframe = { [weak encoder] in encoder?.requestKeyframe() }
        bursts.makeDecoder = { config in
            guard let decoder = try? VideoDecoder(config: config) else { return nil }
            let outbox = DecoderOutbox(hop: { drain in
                DispatchQueue.main.async { batches.begin(); drain(); batches.end() }
            }, deliver: { output in
                batches.add()
                collector.take(output)
            })
            decoder.onFrame = { frame in
                pictures.track(frame.pixelBuffer)
                bursts.output()
                outbox.post(.frame(frame))
            }
            decoder.onDecodeFailure = { seq, error in bursts.output(); outbox.post(.decodeFailure(seq: seq, error: error)) }
            decoder.onSuperseded = { seq in bursts.output(); outbox.post(.superseded(seq: seq)) }
            return decoder
        }
        encoder.onFrame = { frame in bursts.encoded(frame) }
        let refused = OSAllocatedUnfairLock(initialState: 0)
        let feeder = Feeder(page: page, width: width, height: height, deliver: { frame in
            if !encoder.encode(frame.pixelBuffer, captureHostTimeNs: frame.captureHostTimeNs) { refused.withLock { $0 += 1 } }
        })
        let memoryBefore = Memory.now()
        let started = CACurrentMediaTime()
        feeder.start()
        var stalls = 0
        while !bursts.done {
            guard CACurrentMediaTime() - started < 180 else { XCTFail("the 2000 frames were not all handed over in 180 s"); break }
            try await Task.sleep(for: .milliseconds(800))
            usleep(200_000)   // the main actor stalls, as a busy main thread does
            stalls += 1
        }
        let maxAlive = pictures.peakAlive
        let elapsed = CACurrentMediaTime() - started
        feeder.stop()
        encoder.invalidate()
        bursts.decoderForTesting?.drainForTesting()
        try await Task.sleep(for: .milliseconds(300))   // the last drain reaches the main actor
        let memoryAfter = Memory.now()
        let figures = bursts.figures
        let weakDecoder = WeakRef(bursts.decoderForTesting ?? NSObject())
        let aliveWhileShowing = pictures.alive()
        collector.held = nil
        bursts.releaseDecoder()
        try await Task.sleep(for: .milliseconds(300))
        let aliveAfter = pictures.alive()

        report(String(format: "decoder bursts: %d frames handed over in %.1f s, %d main-actor stalls of 200 ms", figures.submitted, elapsed, stalls))
        report("decoder bursts: queued \(figures.queued), fell behind \(figures.fellBehind) (backlog at most \(figures.maxBacklogFrames) frames), skipped \(figures.skipped), refused at the encoder's cap \(refused.withLock { $0 })")
        report("decoder bursts: decoded \(pictures.tracked), superseded \(collector.superseded), failed \(collector.failures), shown \(collector.shown), replaced on the way \(collector.replaced)")
        report("decoder bursts: decoder queue pending at most \(figures.maxPending), outbox batch at most \(batches.largest) outputs over \(batches.drains) drains")
        report("decoder bursts: pictures alive at most \(maxAlive) at once, \(aliveWhileShowing) with one shown, \(aliveAfter) after; \(pictures.distinctSurfaces) surfaces for \(pictures.tracked) pictures")
        report("decoder bursts: out of order \(collector.outOfOrder.prefix(5)), memory before \(memoryBefore), after \(memoryAfter)")

        XCTAssertEqual(figures.submitted, total)
        XCTAssertEqual(collector.outOfOrder.count, 0, "what reaches the main actor comes in decode order: \(collector.outOfOrder.prefix(5))")
        XCTAssertEqual(collector.failures, 0, "no frame fails to decode")
        XCTAssertLessThanOrEqual(figures.maxPending, 2 * VideoDecoder.maxWaiting + 1, "the decoder's queue stays bounded")
        XCTAssertLessThanOrEqual(figures.maxBacklogFrames, VideoDecoder.maxWaiting)
        XCTAssertLessThan(batches.largest, 64, "the outbox holds one hop's worth, not one per frame")
        XCTAssertLessThan(maxAlive, 32, "decoded pictures are let go")
        XCTAssertLessThan(pictures.distinctSurfaces, 48, "the decoder's pool hands the same surfaces out again")
        XCTAssertEqual(aliveAfter, 0, "no decoded pixel buffer outlives the decoder")
        XCTAssertNil(weakDecoder.value, "the decoder is gone")
        XCTAssertGreaterThan(collector.shown, 0)
    }
}

/// Hands the encoder's frames to the decoder ten at a time from a queue of its own, as a network that delivers several
/// at once does, asks the encoder for a keyframe when the decoder falls behind (as the viewer asks the sharer), and
/// counts what `submit` answered and what came out of the decoder's queue.
private final class Bursts: @unchecked Sendable {
    struct Figures { var submitted = 0, queued = 0, fellBehind = 0, skipped = 0, maxPending = 0, maxBacklogFrames = 0 }

    let total: Int
    var makeDecoder: (@Sendable (VideoConfig) -> VideoDecoder?)?
    var requestKeyframe: (@Sendable () -> Void)?
    private let net = DispatchQueue(label: "ai.ronar.nitido.soak.net", qos: .userInteractive)
    private let lock = NSLock()
    // Guarded by `lock`.
    private var collecting: [EncodedFrame] = []
    private var reserved = 0
    private var decoder: VideoDecoder?
    private var counts = Figures()
    private var outputs = 0

    init(total: Int) { self.total = total }

    var figures: Figures { lock.withLock { counts } }
    var done: Bool { lock.withLock { counts.submitted >= total } }
    var decoderForTesting: VideoDecoder? { lock.withLock { decoder } }
    func releaseDecoder() { let d = lock.withLock { defer { decoder = nil }; return decoder }; d?.invalidate() }

    /// On a VideoToolbox queue: one more frame from the encoder.
    func encoded(_ frame: EncodedFrame) {
        let burst: [EncodedFrame]? = lock.withLock {
            guard reserved < total else { return nil }
            reserved += 1
            collecting.append(frame)
            guard collecting.count == 10 else { return nil }
            defer { collecting = [] }
            return collecting
        }
        guard let burst else { return }
        net.async { [self] in submit(burst) }
    }

    /// On the decoder's queue: a frame came out of it, decoded, failed or superseded.
    func output() { lock.withLock { outputs += 1 } }

    private func submit(_ burst: [EncodedFrame]) {
        for frame in burst {
            var target = lock.withLock { decoder }
            if target == nil, let config = frame.videoConfig, let made = makeDecoder?(config) {
                lock.withLock { decoder = made }
                target = made
            }
            guard let target else { lock.withLock { counts.submitted += 1; counts.skipped += 1 }; continue }
            let result = target.submit(frame.videoFrame)
            lock.withLock {
                counts.submitted += 1
                switch result {
                case .queued: counts.queued += 1
                case .fellBehind(let backlog): counts.fellBehind += 1; counts.maxBacklogFrames = max(counts.maxBacklogFrames, backlog.frames)
                case .skipped: counts.skipped += 1
                }
                counts.maxPending = max(counts.maxPending, counts.queued - outputs)
            }
            if case .fellBehind = result { requestKeyframe?() }
        }
    }
}

/// How many outputs each drain of the outbox hands the main actor.
private final class Batches: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private var most = 0
    private var count = 0
    func begin() { lock.withLock { current = 0 } }
    func add() { lock.withLock { current += 1 } }
    func end() { lock.withLock { most = max(most, current); count += 1 } }
    var largest: Int { lock.withLock { most } }
    var drains: Int { lock.withLock { count } }
}

/// What the outbox hands the main actor: the newest picture kept as a view keeps the one it shows, every sequence number
/// checked against the one before.
@MainActor
private final class OutboxCollector {
    var held: CVPixelBuffer?
    var shown = 0, replaced = 0, superseded = 0, failures = 0
    var outOfOrder: [(UInt32, UInt32)] = []
    private var last: UInt32?

    func take(_ output: DecoderOutbox.Output) {
        let seq: UInt32
        switch output {
        case .frame(let frame): seq = frame.seq; shown += 1; held = frame.pixelBuffer
        case .replaced(let s): seq = s; replaced += 1
        case .decodeFailure(let s, _): seq = s; failures += 1
        case .superseded(let s): seq = s; superseded += 1
        }
        if let last, seq <= last { outOfOrder.append((last, seq)) }
        last = seq
    }
}
