import SugarbarCore
import SugarbarUI
import SwiftUI

struct LockScreenRectangularView: View {
    let entry: GlucoseEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(entry.content.text ?? "—")
                    .font(.headline)
                if let symbol = entry.content.trendSymbol {
                    Image(systemName: symbol)
                }
            }
            if let value = entry.content.value {
                Gauge(value: clamped(value), in: entry.thresholds.urgentLow...entry.thresholds.urgentHigh) {
                    EmptyView()
                }
                .gaugeStyle(.accessoryLinear)
            }
            stateLine
                .font(.caption2)
        }
        .containerBackground(.clear, for: .widget)
    }

    @ViewBuilder
    private var stateLine: some View {
        switch entry.content {
        case .warmingUp:
            Text("Warming up")
        case .empty:
            Text("No data")
        case .live, .stale:
            if let timestamp = entry.latest?.timestamp {
                Text(timestamp, style: .relative)
            }
        }
    }

    private func clamped(_ value: Double) -> Double {
        min(max(value, entry.thresholds.urgentLow), entry.thresholds.urgentHigh)
    }
}
