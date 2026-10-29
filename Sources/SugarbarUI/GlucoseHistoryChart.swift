import Charts
import SwiftUI
import SugarbarCore

/// A platform-neutral history chart: readings against the reference range, with
/// threshold lines, the latest point highlighted, insulin doses and meals marked
/// along the floor, and drag-to-inspect selection.
public struct GlucoseHistoryChart: View {
    private let series: [Reading]
    private let doses: [InsulinDose]
    private let meals: [Meal]
    private let thresholds: Thresholds
    private let latest: Reading?
    private let valueTint: Color
    private let xDomain: ClosedRange<Date>
    @Binding private var selectedDate: Date?

    public init(
        series: [Reading],
        doses: [InsulinDose] = [],
        meals: [Meal] = [],
        thresholds: Thresholds,
        latest: Reading?,
        valueTint: Color,
        xDomain: ClosedRange<Date>,
        selectedDate: Binding<Date?>
    ) {
        self.series = series
        self.doses = doses
        self.meals = meals
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
                let isHovered = hoveredDoses.contains(dose)
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

            ForEach(meals) { meal in
                let isHovered = hoveredMeals.contains(meal)
                PointMark(
                    x: .value("Time", meal.timestamp),
                    y: .value("mmol/L", mealBaseline)
                )
                .symbol(.square)
                .symbolSize(isHovered ? 110 : 55)
                .foregroundStyle(mealTint)
                .annotation(position: .trailing, spacing: 3, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                    Text("\(formatGrams(meal.carbsGrams)) g")
                        .font(.caption2)
                        .foregroundStyle(mealTint)
                }
            }

            if let selected = nearestReading(to: selectedDate, in: series) {
                selectionMarks(for: selected, doses: hoveredDoses, meals: hoveredMeals)
            }
        }
        .chartXSelection(value: $selectedDate)
        .chartXScale(domain: xDomain)
        .chartYScale(domain: yDomain)
        .frame(height: 180)
    }

    /// Doses and meals close enough to the hovered time join the selection tooltip.
    private var hoveredDoses: [InsulinDose] {
        guard let selectedDate else { return [] }
        return insulinDoses(near: selectedDate, in: doses, tolerance: hoverTolerance)
    }

    private var hoveredMeals: [Meal] {
        guard let selectedDate else { return [] }
        return SugarbarCore.meals(near: selectedDate, in: meals, tolerance: hoverTolerance)
    }

    private var hoverTolerance: TimeInterval {
        xDomain.upperBound.timeIntervalSince(xDomain.lowerBound) / 60
    }

    private func nearestReading(to date: Date?, in series: [Reading]) -> Reading? {
        guard let date else { return nil }
        return SugarbarCore.nearestReading(to: date, in: series)
    }

    @ChartContentBuilder
    private func selectionMarks(for reading: Reading, doses: [InsulinDose], meals: [Meal]) -> some ChartContent {
        RuleMark(x: .value("Time", reading.timestamp))
            .lineStyle(StrokeStyle(lineWidth: 1))
            .foregroundStyle(.secondary.opacity(0.5))
            .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                Text("\(formatMmolPerL(reading.value)) mmol/L")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
            }
            .annotation(position: .bottom, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(reading.timestamp, format: .dateTime.hour().minute())
                        .foregroundStyle(.secondary)
                    ForEach(doses) { dose in
                        Text("\(dose.timestamp, format: .dateTime.hour().minute()) · \(formatUnits(dose.units)) u · \(dose.insulinName ?? dose.kind.label)")
                            .fontWeight(.semibold)
                            .foregroundStyle(dose.kind.tint)
                    }
                    ForEach(meals) { meal in
                        Text("\(meal.timestamp, format: .dateTime.hour().minute()) · \(formatGrams(meal.carbsGrams)) g · \(meal.summary)")
                            .fontWeight(.semibold)
                            .foregroundStyle(mealTint)
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

    /// Doses and meals sit in a strip below the glucose range so their markers never collide with
    /// the line. A bolus is usually logged at mealtime, so meals get their own row when both exist.
    private var yDomain: ClosedRange<Double> {
        let values = series.map(\.value)
        let low = min(values.min() ?? thresholds.urgentLow, thresholds.urgentLow) - 0.5
        let high = max(values.max() ?? thresholds.urgentHigh, thresholds.urgentHigh) + 0.5
        return max(0, low - stripHeight)...high
    }

    private var stripHeight: Double {
        switch (doses.isEmpty, meals.isEmpty) {
        case (true, true): 0
        case (false, false): 2.4
        default: 1.4
        }
    }

    private var doseBaseline: Double { yDomain.lowerBound + (meals.isEmpty ? 0.35 : 1.4) }

    private var mealBaseline: Double { yDomain.lowerBound + 0.35 }
}

public let mealTint: Color = .orange

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
