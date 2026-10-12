import SwiftUI
import AppKit
import NitidoCore

/// One quiet row of figures (wrapped only when the picture is narrower than the row). Gold while a value is over
/// its threshold, never red.
public struct TelemetryStrip: View {
    /// The strip's own labels, set in Marcellus small caps (`Figure`). Each screen names its latency figure itself
    /// (`ShareView.latencyLabel`, `ViewView.latencyLabel`) and says whether its first figure counts frames captured or
    /// received.
    public enum Label {
        public static let capture = "capture", received = "received", display = "display", codec = "codec", rtt = "rtt"
        public static let bitrate = "bitrate", dropped = "dropped", size = "size"
    }
    /// Every label above: the bundled Marcellus has no fallback for a character it lacks, so a test checks them all.
    static let fixedLabels = [Label.capture, Label.received, Label.display, Label.codec, Label.rtt, Label.bitrate, Label.dropped, Label.size]

    public let snapshot: Snapshot
    public let resolution: String
    public let codec: String
    public let latencyLabel: String
    public let codecMs: Double?
    /// The codec figure is shown: while the codec loop is on (its figure says "·" until the loop has timed a frame),
    /// or whenever there is a figure. The viewer has none.
    public let showsCodec: Bool
    /// What the first figure counts: frames captured on the sharer, frames received on the viewer.
    public let captureLabel: String

    public init(snapshot: Snapshot, resolution: String, codec: String, latencyLabel: String, codecMs: Double? = nil,
                showsCodec: Bool = false, captureLabel: String = Label.capture) {
        self.snapshot = snapshot; self.resolution = resolution; self.codec = codec; self.latencyLabel = latencyLabel
        self.codecMs = codecMs; self.showsCodec = showsCodec || codecMs != nil; self.captureLabel = captureLabel
    }

    private var latencyHigh: Bool { (snapshot.latencyMs ?? 0) > 100 }
    private var dropping: Bool { snapshot.droppedLastSecond > 0 }

    /// One row when the strip is wide enough; narrower than that (the picture is narrower), the figures wrap
    /// onto another row instead of widening the strip, so the window stays exactly as wide as the picture. The codec
    /// figure is there only while it has one (the codec loop on the sharer; never on the viewer), which keeps a 720 pt
    /// picture on one row. Solid, not glass: glass under the picture refracts nothing and only adds a grey band, so the
    /// strip is the surface with a hairline along its top, one dark family with the canvas.
    public var body: some View {
        StripRows(spacing: 16, rowSpacing: 6, sparklineGap: 8) {
            Figure(captureLabel, value: fps(snapshot.captureFPS), unit: "fps", number: snapshot.captureFPS)
            Figure(Label.display, value: fps(snapshot.displayFPS), unit: "fps", number: snapshot.displayFPS)
            Figure(latencyLabel, value: ms(snapshot.latencyMs), unit: "ms", number: snapshot.latencyMs, highlight: latencyHigh)
            if showsCodec {
                // In with the loop, 80 ms after the switch, as the figures after it make room; out faster.
                Figure(Label.codec, value: ms(codecMs), unit: "ms", number: codecMs)
                    .transition(AsymmetricTransition(insertion: .opacity.animation(TelemetryMotion.codecIn.animation(after: TelemetryMotion.codecDelay)),
                                                     removal: .opacity.animation(TelemetryMotion.codecOut.animation)))
            }
            Figure(Label.rtt, value: ms(snapshot.rttMs), unit: "ms", number: snapshot.rttMs)
            Figure(Label.bitrate, value: snapshot.bitrateMbps > 0 ? String(format: "%.1f", snapshot.bitrateMbps) : "·", unit: "Mbps",
                   number: snapshot.bitrateMbps)
            // "·" until frames come, as every other figure says nothing yet.
            Figure(Label.dropped, value: snapshot.captureFPS > 0 || dropping ? "\(snapshot.droppedLastSecond)" : "·", unit: "/s",
                   number: Double(snapshot.droppedLastSecond), highlight: dropping)
            // A change of size or codec is structural, not a count: it crossfades.
            Figure(Label.size, value: resolution, unit: codec)
            Sparkline(buckets: snapshot.latencyBuckets, newest: snapshot.newestBucket).frame(width: 80, height: 18)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Theme.Colors.surface)
        .overlay(alignment: .top) { Rectangle().fill(Theme.Colors.hairline).frame(height: 1) }
    }

    private func fps(_ v: Double) -> String { v > 0 ? "\(Int(v.rounded()))" : "·" }
    private func ms(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? "·" }
}

/// The strip's motion (spec 11, M11): figures that change like an instrument, not a slot machine.
enum TelemetryMotion {
    /// A count's numeric roll: up when it rises, down when it falls (`Theme.Motion.figure`, 180 ms).
    static let roll = Theme.Motion.figure
    /// Under Reduce Motion the roll is a 120 ms crossfade.
    static let reducedRoll = Theme.Motion.Curve(Theme.Motion.easeOut, 0.12)
    /// A structural change (the size, the codec, "·" to a first value) crossfades over 180 ms, ease.
    static let crossfade = Theme.Motion.Curve(Theme.Motion.ease, 0.18)
    /// Over a threshold: to gold over 120 ms on the strong ease-out; back to the text colour over 400 ms when it clears.
    static let warn = Theme.Motion.enter.over(0.12)
    static let clear = Theme.Motion.Curve(Theme.Motion.systemEaseInOut, 0.4)
    /// The codec figure with the loop: in over 180 ms after 80 ms, out over 100 ms.
    static let codecIn = Theme.Motion.enter.over(0.18)
    static let codecDelay: Double = 0.08
    static let codecOut = Theme.Motion.exit.over(0.1)
}

private struct Figure: View {
    let label: String, value: String, unit: String
    /// The figure's value as a number, for its numeric roll; nil for a figure that is not a count (the size).
    var number: Double?
    var highlight = false
    @ReducedMotion private var reduceMotion
    /// The figure's slot: as wide as the widest value it has shown since the strip appeared, so 9 → 10 ms moves the
    /// figures after it once, never back and forth. A reference, grown as the body reads it.
    @State private var slot = Slot()

    final class Slot {
        private(set) var characters = 0
        /// The value before the current change, for the kind of transition it gets.
        var previous: String?
        /// The slot's width in characters once it holds `count`: it only grows.
        func grow(to count: Int) -> Int { characters = max(characters, count); return characters }
    }

    init(_ label: String, value: String, unit: String, number: Double? = nil, highlight: Bool = false) {
        self.label = label; self.value = value; self.unit = unit; self.number = number; self.highlight = highlight
    }

    /// The width of one character of the figures' face (SF Mono, so every character is as wide).
    static let advance: CGFloat = {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        return ceil(("0" as NSString).size(withAttributes: [.font: font]).width * 2) / 2
    }()

    var body: some View {
        let characters = slot.grow(to: value.count)
        let counts = number != nil && value != "·" && slot.previous != "·" && slot.previous != nil
        let roll = !reduceMotion && counts
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased()).font(Theme.Fonts.smallCaps(10)).foregroundStyle(Theme.Colors.secondaryText).tracking(1.2)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(Theme.Fonts.figures(12)).foregroundStyle(highlight ? Theme.Colors.gold : Theme.Colors.text)
                    .contentTransition(roll ? .numericText(value: number ?? 0) : .opacity)
                    .animation((roll ? TelemetryMotion.roll : reduceMotion && counts ? TelemetryMotion.reducedRoll : TelemetryMotion.crossfade).animation,
                               value: value)
                    .animation((highlight ? TelemetryMotion.warn : TelemetryMotion.clear).animation, value: highlight)
                    .frame(minWidth: CGFloat(characters) * Self.advance, alignment: .leading)
                Text(unit).font(Theme.Fonts.figures(10)).foregroundStyle(Theme.Colors.secondaryText)
                    .contentTransition(.opacity)
                    .animation(TelemetryMotion.crossfade.animation, value: unit)
            }
        }
        // A figure wider than a whole row (a tiny picture) is truncated, never wrapped onto a second line.
        .lineLimit(1)
        .onChange(of: value, initial: true) { _, new in slot.previous = new }
    }
}

/// The strip's figures as shown (spec 11, M11): an instrument, not a slot machine. An integer figure (frames a second,
/// milliseconds) that moves by one shows once it has held for two snapshots more (half a second), so 59/60 does not
/// flicker; a move of two or more shows at once. The bitrate, to one decimal, the same with 0.3 Mbps. Dropped frames
/// always show at once: that figure warns. A figure appearing or going ("·") shows at once. It never hides a move of
/// two or more and never delays one by more than half a second; the logs and the measurements read the raw snapshot.
struct FigureHysteresis {
    /// One figure's gate.
    struct Gate {
        /// Moves this large show at once; smaller ones wait.
        let big: Double
        private(set) var shown: Double?
        private var pending: Double?
        private var held = 0

        init(big: Double) { self.big = big }

        /// Snapshots a small move must hold for, after the one it first appears in.
        static let hold = 2

        /// The value to show for `value` (already rounded as the strip shows it; nil or 0 for none).
        mutating func pass(_ value: Double?) -> Double? {
            guard let value, value != 0, let current = shown, current != 0 else {
                shown = value; pending = nil; held = 0
                return value
            }
            let move = abs(value - current)
            if move < 1e-9 { pending = nil; held = 0; return current }
            if move >= big - 1e-9 { shown = value; pending = nil; held = 0; return value }
            if let pending, abs(pending - value) < 1e-9 {
                held += 1
                if held >= Self.hold { shown = value; self.pending = nil; held = 0; return value }
            } else {
                pending = value; held = 0
            }
            return current
        }
    }

    private var capture = Gate(big: 2), display = Gate(big: 2), latency = Gate(big: 2), rtt = Gate(big: 2)
    private var bitrate = Gate(big: 0.3)

    /// `raw` as the strip shows it.
    mutating func apply(_ raw: Snapshot) -> Snapshot {
        var shown = raw
        shown.captureFPS = capture.pass(raw.captureFPS.rounded()) ?? 0
        shown.displayFPS = display.pass(raw.displayFPS.rounded()) ?? 0
        shown.latencyMs = latency.pass(raw.latencyMs.map { $0.rounded() })
        shown.rttMs = rtt.pass(raw.rttMs.map { $0.rounded() })
        shown.bitrateMbps = bitrate.pass((raw.bitrateMbps * 10).rounded() / 10) ?? 0
        return shown
    }
}

/// Latency over the last two seconds (spec 11, M11), scaled to at least 120 ms so the baseline reads as calm, over a
/// hairline at the 100 ms threshold so the gold line has a reference. Drawn in time, not by sample: 50 ms buckets on a
/// fixed grid (`Snapshot.latencyBuckets`), so the line does not stretch with the frame rate and a pause shows as a gap.
/// It slides: each snapshot (four a second) sets the line's new path, which holds the buckets come since the last one
/// past the right edge, and Core Animation moves it left by that many buckets over the time they cover, linear, on the
/// render server, so the newest bucket reaches the right edge as the next snapshot lands and the main thread touches it
/// once a snapshot, never per frame. An estimate below zero (a clock offset that is off) is drawn on the baseline.
/// Under Reduce Motion it steps at each snapshot.
struct Sparkline: NSViewRepresentable {
    let buckets: [Double?]
    let newest: Int
    func makeNSView(context: Context) -> SparklineView { SparklineView() }
    func updateNSView(_ view: SparklineView, context: Context) {
        view.update(buckets: buckets, newest: newest, sliding: !context.environment.reducesMotion)
    }
}

final class SparklineView: NSView {
    private let slider = CALayer()
    private let line = CAShapeLayer()
    private let hairline = CALayer()
    /// The newest bucket the line was last drawn up to.
    private(set) var shownNewest: Int?
    /// The buckets the sparkline shows across its width.
    nonisolated static let visible = 40

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        hairline.backgroundColor = NSColor(hex: Theme.Hex.hairline).cgColor
        line.fillColor = nil
        line.strokeColor = Theme.CanvasColors.gold.cgColor
        line.lineWidth = 1
        line.lineCap = .round
        line.lineJoin = .round
        slider.addSublayer(line)
        layer?.addSublayer(hairline)
        layer?.addSublayer(slider)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        slider.frame = bounds
        line.frame = bounds
        CATransaction.commit()
    }

    /// How far the line slides for a snapshot `advance` buckets after the last, and over how long.
    nonisolated static func slide(advance: Int, bucketWidth: CGFloat) -> (distance: CGFloat, duration: Double) {
        (CGFloat(advance) * bucketWidth, Double(advance) * Snapshot.bucketWidth)
    }

    func update(buckets: [Double?], newest: Int, sliding: Bool) {
        guard newest != shownNewest, !buckets.isEmpty else { return }
        let w = max(bounds.width, 1), h = max(bounds.height, 1)
        let bucketWidth = w / CGFloat(Self.visible - 1)
        let advance = sliding ? shownNewest.map { min(max(newest - $0, 0), buckets.count - Self.visible) } ?? 0 : 0
        shownNewest = newest
        let shownValues = buckets.suffix(Self.visible + advance).compactMap { $0 }
        let top = max(120, shownValues.max() ?? 0)
        // At no translation the bucket the line was last drawn up to sits at the right edge, where the last slide left it;
        // the line then slides left by the buckets come since.
        let path = CGMutablePath()
        var drawing = false
        for (index, value) in buckets.enumerated() {
            let bucket = newest - (buckets.count - 1) + index
            let x = w - CGFloat(newest - advance - bucket) * bucketWidth
            guard let value, x >= -bucketWidth else { drawing = false; continue }
            let y = h * (1 - CGFloat(min(max(value, 0), top) / top))
            if drawing { path.addLine(to: CGPoint(x: x, y: y)) } else { path.move(to: CGPoint(x: x, y: y)); drawing = true }
        }
        let slide = Self.slide(advance: advance, bucketWidth: bucketWidth)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        line.path = path
        hairline.frame = CGRect(x: 0, y: (h * (1 - CGFloat(100 / top))).rounded() - 0.5, width: w, height: 1)
        slider.removeAnimation(forKey: "slide")
        slider.transform = CATransform3DMakeTranslation(-slide.distance, 0, 0)
        CATransaction.commit()
        guard slide.distance > 0 else { return }
        let animation = CABasicAnimation(keyPath: "transform.translation.x")
        animation.fromValue = 0
        animation.toValue = -slide.distance
        animation.duration = slide.duration
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        slider.add(animation, forKey: "slide")
    }
}

/// Places the strip's items left to right and starts a new row when the next one does not fit, so the strip is
/// exactly as wide as it is offered (the picture's width) and grows in height instead of setting the window's
/// width. The last item (the sparkline) sits at the trailing end of its row, with at least `sparklineGap` of
/// free space plus `spacing` on each side before it, as the old one-row spacer gave it.
struct StripRows: Layout {
    var spacing: CGFloat
    var rowSpacing: CGFloat
    var sparklineGap: CGFloat

    private struct Item {
        let index: Int
        let x: CGFloat
        let size: CGSize
    }

    private struct Row {
        var items: [Item] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width)
        let height = rows.reduce(0) { $0 + $1.height } + rowSpacing * CGFloat(max(0, rows.count - 1))
        // Any finite width offered is taken whole; with none (an ideal size query), one row's width.
        let natural = rows.map(\.width).max() ?? 0
        guard let offered = proposal.width, offered.isFinite else { return CGSize(width: natural, height: height) }
        return CGSize(width: offered, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            for item in row.items {
                let trailing = item.index == subviews.count - 1
                let x = trailing ? bounds.maxX - item.size.width : bounds.minX + item.x
                subviews[item.index].place(at: CGPoint(x: x, y: y + (row.height - item.size.height) / 2),
                                           proposal: ProposedViewSize(item.size))
            }
            y += row.height + rowSpacing
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat?) -> [Row] {
        let limit = width ?? .infinity
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            if size.width > limit {
                // Wider than a whole row: offered the row's width, so it truncates instead of overflowing.
                size = subviews[index].sizeThatFits(ProposedViewSize(width: limit, height: nil))
            }
            let gap = index == subviews.count - 1 ? spacing + sparklineGap + spacing : spacing
            if !row.items.isEmpty, row.width + gap + size.width > limit {
                rows.append(row)
                row = Row()
            }
            let x = row.items.isEmpty ? 0 : row.width + gap
            row.items.append(Item(index: index, x: x, size: size))
            row.width = x + size.width
            row.height = max(row.height, size.height)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}
