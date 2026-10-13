import Charts
import SwiftUI
import SugarbarCore

/// A platform-neutral history chart: readings against the reference range, with
/// threshold lines, the latest point highlighted, insulin doses marked along the
/// floor, and drag-to-inspect selection.
public struct GlucoseHistoryChart: View {
    private let series: [Reading]
    private let doses: [InsulinDose]
    private let thresholds: Thresholds
    private let latest: Reading?
    private let valueTint: Color
    private let xDomain: ClosedRange<Date>
    @Binding private var selectedDate: Date?

    public init(
        series: [Reading],
        doses: [InsulinDose] = [],
        thresholds: Thresholds,
        latest: Reading?,
        valueTint: Color,
        xDomain: ClosedRange<Date>,
        selectedDate: Binding<Date?>
    ) {
        self.series = series
        self.doses = doses
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

            ForEach(doses) { dose in
                let isHovered = dose == hoveredDose
                PointMark(
                    x: .value("Time", dose.timestamp),
                    y: .value("mmol/L", doseBaseline)
                )
                .symbol(dose.kind == .bolus ? .circle : .diamond)
                .symbolSize(isHovered ? 110 : (dose.kind == .bolus ? 50 : 60))
                .foregroundStyle(dose.kind.tint)
                .annotation(position: .top, spacing: 1) {
                    Text(formatUnits(dose.units))
                        .font(.caption2)
                        .foregroundStyle(dose.kind.tint)
                }
            }

            if let selected = nearestReading(to: selectedDate, in: series) {
                selectionMarks(for: selected, dose: hoveredDose)
            }
        }
        .chartXSelection(value: $selectedDate)
        .chartXScale(domain: xDomain)
        .chartYScale(domain: yDomain)
        .frame(height: 180)
    }

    /// A dose close enough to the hovered time joins the selection tooltip.
    private var hoveredDose: InsulinDose? {
        guard let selectedDate else { return nil }
        let tolerance = xDomain.upperBound.timeIntervalSince(xDomain.lowerBound) / 60
        return nearestInsulinDose(to: selectedDate, in: doses, tolerance: tolerance)
    }

    private func nearestReading(to date: Date?, in series: [Reading]) -> Reading? {
        guard let date else { return nil }
        return SugarbarCore.nearestReading(to: date, in: series)
    }

    @ChartContentBuilder
    private func selectionMarks(for reading: Reading, dose: InsulinDose?) -> some ChartContent {
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
                HStack(spacing: 4) {
                    Text(reading.timestamp, format: .dateTime.hour().minute())
                        .foregroundStyle(.secondary)
                    if let dose {
                        Text("· \(formatUnits(dose.units)) u \(dose.insulinName ?? dose.kind.label)")
                            .fontWeight(.semibold)
                            .foregroundStyle(dose.kind.tint)
                    }
                }
                .font(.caption2)
                .fixedSize()
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

    /// Doses sit in a strip below the glucose range so their markers never collide with the line.
    private var yDomain: ClosedRange<Double> {
        let values = series.map(\.value)
        let low = min(values.min() ?? thresholds.urgentLow, thresholds.urgentLow) - 0.5
        let high = max(values.max() ?? thresholds.urgentHigh, thresholds.urgentHigh) + 0.5
        return max(0, low - (doses.isEmpty ? 0 : doseStripHeight))...high
    }

    private let doseStripHeight = 1.4

    private var doseBaseline: Double { yDomain.lowerBound + 0.35 }
}

public extension InsulinKind {
    var tint: Color {
        switch self {
        case .bolus: .blue
        case .basal: .purple
        }
    }

    var label: String {
        switch self {
        case .bolus: "bolus"
        case .basal: "basal"
        }
    }
}
