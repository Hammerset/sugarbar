import Charts
import SwiftUI
import SugarbarCore

/// A platform-neutral history chart: readings against the reference range, with
/// threshold lines, the latest point highlighted, and drag-to-inspect selection.
public struct GlucoseHistoryChart: View {
    private let series: [Reading]
    private let thresholds: Thresholds
    private let latest: Reading?
    private let valueTint: Color
    private let xDomain: ClosedRange<Date>
    @Binding private var selectedDate: Date?

    public init(
        series: [Reading],
        thresholds: Thresholds,
        latest: Reading?,
        valueTint: Color,
        xDomain: ClosedRange<Date>,
        selectedDate: Binding<Date?>
    ) {
        self.series = series
        self.thresholds = thresholds
        self.latest = latest
        self.valueTint = valueTint
        self.xDomain = xDomain
        self._selectedDate = selectedDate
    }

    public var body: some View {
        if series.isEmpty {
            emptyState
        } else {
            chart
        }
    }

    private var emptyState: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4))
            Text("No recent history")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(height: 180)
    }

    private var chart: some View {
        Chart {
            RectangleMark(
                yStart: .value("In-range low", thresholds.low),
                yEnd: .value("In-range high", thresholds.high)
            )
            .foregroundStyle(.green.opacity(0.12))

            ForEach(thresholdLines, id: \.value) { line in
                RuleMark(y: .value("Threshold", line.value))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(line.color.opacity(0.4))
            }

            ForEach(series, id: \.timestamp) { reading in
                LineMark(
                    x: .value("Time", reading.timestamp),
                    y: .value("mmol/L", reading.value)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(.primary)
            }

            if let latest {
                PointMark(
                    x: .value("Time", latest.timestamp),
                    y: .value("mmol/L", latest.value)
                )
                .foregroundStyle(valueTint)
            }

            if let selected = nearestReading(to: selectedDate, in: series) {
                selectionMarks(for: selected)
            }
        }
        .chartXSelection(value: $selectedDate)
        .chartXScale(domain: xDomain)
        .chartYScale(domain: yDomain(for: series))
        .frame(height: 180)
    }

    private func nearestReading(to date: Date?, in series: [Reading]) -> Reading? {
        guard let date else { return nil }
        return SugarbarCore.nearestReading(to: date, in: series)
    }

    @ChartContentBuilder
    private func selectionMarks(for reading: Reading) -> some ChartContent {
        RuleMark(x: .value("Time", reading.timestamp))
            .lineStyle(StrokeStyle(lineWidth: 1))
            .foregroundStyle(.secondary.opacity(0.5))
            .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                Text("\(formatMmolPerL(reading.value)) mmol/L")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
            }
            .annotation(position: .bottom, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                Text(reading.timestamp, format: .dateTime.hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.background, in: RoundedRectangle(cornerRadius: 4))
            }

        PointMark(
            x: .value("Time", reading.timestamp),
            y: .value("mmol/L", reading.value)
        )
        .foregroundStyle(Band(mmolPerL: reading.value, thresholds: thresholds).tint)
        .symbolSize(80)
    }

    private var thresholdLines: [(value: Double, color: Color)] {
        [
            (thresholds.urgentLow, .red),
            (thresholds.low, .green),
            (thresholds.high, .green),
            (thresholds.urgentHigh, .red),
        ]
    }

    private func yDomain(for series: [Reading]) -> ClosedRange<Double> {
        let values = series.map(\.value)
        let low = min(values.min() ?? thresholds.urgentLow, thresholds.urgentLow) - 0.5
        let high = max(values.max() ?? thresholds.urgentHigh, thresholds.urgentHigh) + 0.5
        return max(0, low)...high
    }
}
