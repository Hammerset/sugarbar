import Charts
import SugarbarCore
import SwiftUI

/// A static history line for the medium widget — no selection, no threshold rules;
/// a widget has no room or gesture surface for `GlucoseHistoryChart`'s interactivity.
struct GlucoseSparkline: View {
    let history: [Reading]
    let thresholds: Thresholds

    var body: some View {
        if history.isEmpty {
            Color.clear
        } else {
            Chart(history, id: \.timestamp) { reading in
                LineMark(
                    x: .value("Time", reading.timestamp),
                    y: .value("mmol/L", reading.value)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(.secondary)
            }
            .chartYScale(domain: yDomain)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
        }
    }

    private var yDomain: ClosedRange<Double> {
        let values = history.map(\.value)
        let low = min(values.min() ?? thresholds.urgentLow, thresholds.urgentLow) - 0.5
        let high = max(values.max() ?? thresholds.urgentHigh, thresholds.urgentHigh) + 0.5
        return max(0, low)...high
    }
}
