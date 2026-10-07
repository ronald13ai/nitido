import SwiftUI
import NitidoCore

/// One quiet row of figures. Gold while a value is over its threshold, never red.
public struct TelemetryStrip: View {
    public let snapshot: Snapshot
    public let resolution: String
    public let codec: String
    public let latencyLabel: String

    public init(snapshot: Snapshot, resolution: String, codec: String, latencyLabel: String) {
        self.snapshot = snapshot; self.resolution = resolution; self.codec = codec; self.latencyLabel = latencyLabel
    }

    private var latencyHigh: Bool { (snapshot.latencyMs ?? 0) > 100 }
    private var dropping: Bool { snapshot.droppedLastSecond > 0 }

    public var body: some View {
        HStack(spacing: 18) {
            Figure("capture", value: fps(snapshot.captureFPS), unit: "fps")
            Figure("display", value: fps(snapshot.displayFPS), unit: "fps")
            Figure(latencyLabel, value: ms(snapshot.latencyMs), unit: "ms", highlight: latencyHigh)
            Figure("rtt", value: ms(snapshot.rttMs), unit: "ms")
            Figure("bitrate", value: snapshot.bitrateMbps > 0 ? String(format: "%.1f", snapshot.bitrateMbps) : "·", unit: "Mbps")
            Figure("dropped", value: "\(snapshot.droppedLastSecond)", unit: "/s", highlight: dropping)
            Figure("size", value: resolution, unit: codec)
            Spacer(minLength: 8)
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
