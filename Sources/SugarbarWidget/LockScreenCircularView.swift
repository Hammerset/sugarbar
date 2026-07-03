import SugarbarCore
import SugarbarUI
import SwiftUI

/// Lock Screen renders monochrome, so band comes across via the gauge's fill amount,
/// not colour — the same invariant as everywhere else: no reading never reads as live.
struct LockScreenCircularView: View {
    let entry: GlucoseEntry

    var body: some View {
        Group {
            if let value = entry.content.value {
                Gauge(value: clamped(value), in: entry.thresholds.urgentLow...entry.thresholds.urgentHigh) {
                    EmptyView()
                } currentValueLabel: {
                    Text(entry.content.text ?? "—")
                        .font(.system(.caption2, design: .rounded))
                }
                .gaugeStyle(.accessoryCircular)
            } else if case .warmingUp = entry.content {
                Image(systemName: "hourglass")
                    .font(.title3)
            } else {
                Image(systemName: "drop")
                    .font(.title3)
            }
        }
        .containerBackground(.clear, for: .widget)
    }

    private func clamped(_ value: Double) -> Double {
        min(max(value, entry.thresholds.urgentLow), entry.thresholds.urgentHigh)
    }
}
