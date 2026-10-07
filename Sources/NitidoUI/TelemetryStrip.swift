import SwiftUI
import NitidoCore

/// One quiet row of figures (wrapped only when the picture is narrower than the row). Gold while a value is over
/// its threshold, never red.
public struct TelemetryStrip: View {
    public let snapshot: Snapshot
    public let resolution: String
    public let codec: String
    public let latencyLabel: String
    public let codecMs: Double?

    public init(snapshot: Snapshot, resolution: String, codec: String, latencyLabel: String, codecMs: Double? = nil) {
        self.snapshot = snapshot; self.resolution = resolution; self.codec = codec; self.latencyLabel = latencyLabel
        self.codecMs = codecMs
    }

    private var latencyHigh: Bool { (snapshot.latencyMs ?? 0) > 100 }
    private var dropping: Bool { snapshot.droppedLastSecond > 0 }

    /// One row when the strip is wide enough; narrower than that (the picture is narrower), the figures wrap
    /// onto another row instead of widening the strip, so the window stays exactly as wide as the picture.
    public var body: some View {
        StripRows(spacing: 18, rowSpacing: 6, sparklineGap: 8) {
            Figure("capture", value: fps(snapshot.captureFPS), unit: "fps")
            Figure("display", value: fps(snapshot.displayFPS), unit: "fps")
            Figure(latencyLabel, value: ms(snapshot.latencyMs), unit: "ms", highlight: latencyHigh)
            Figure("codec", value: ms(codecMs), unit: "ms")
            Figure("rtt", value: ms(snapshot.rttMs), unit: "ms")
            Figure("bitrate", value: snapshot.bitrateMbps > 0 ? String(format: "%.1f", snapshot.bitrateMbps) : "·", unit: "Mbps")
            Figure("dropped", value: "\(snapshot.droppedLastSecond)", unit: "/s", highlight: dropping)
            Figure("size", value: resolution, unit: codec)
            Sparkline(values: snapshot.latencySeries).frame(width: 96, height: 18)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Theme.Colors.surface)
        .overlay(alignment: .top) { Rectangle().fill(Theme.Colors.hairline).frame(height: 1) }
    }

    private func fps(_ v: Double) -> String { v > 0 ? "\(Int(v.rounded()))" : "·" }
    private func ms(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? "·" }
}

private struct Figure: View {
    let label: String, value: String, unit: String
    var highlight = false
    init(_ label: String, value: String, unit: String, highlight: Bool = false) {
        self.label = label; self.value = value; self.unit = unit; self.highlight = highlight
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased()).font(Theme.Fonts.smallCaps(8)).foregroundStyle(Theme.Colors.muted).tracking(1)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(Theme.Fonts.figures(12)).foregroundStyle(highlight ? Theme.Colors.gold : Theme.Colors.text)
                Text(unit).font(Theme.Fonts.figures(9)).foregroundStyle(Theme.Colors.muted)
            }
        }
        // A figure wider than a whole row (a tiny picture) is truncated, never wrapped onto a second line.
        .lineLimit(1)
    }
}

/// Latency over the last two seconds, scaled to at least 120 ms so the baseline reads as calm.
private struct Sparkline: View {
    let values: [Double]
    var body: some View {
        GeometryReader { geo in
            let top = max(120, values.max() ?? 0)
            Path { path in
                guard values.count > 1 else { return }
                for (i, v) in values.enumerated() {
                    let x = geo.size.width * CGFloat(i) / CGFloat(values.count - 1)
                    let y = geo.size.height * (1 - CGFloat(v / top))
                    i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            .stroke(Theme.Colors.gold, style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
        }
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
