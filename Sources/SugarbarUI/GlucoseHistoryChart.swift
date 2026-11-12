import Charts
import SwiftUI
import SugarbarCore

/// A platform-neutral history chart: readings against the reference range, with
/// threshold lines, the latest point highlighted, insulin doses and meals marked
/// along the floor, and drag-to-inspect selection.
public struct GlucoseHistoryChart: View {
    private let series: [Reading]
    private let segments: [[Reading]]
    private let envelope: [[GlucoseEnvelope]]
    private let doses: [InsulinDose]
    private let meals: [Meal]
    private let thresholds: Thresholds
    private let latest: Reading?
    private let valueTint: Color
    private let xDomain: ClosedRange<Date>
    private let markerBucket: TimeInterval?
    @Binding private var selectedDate: Date?

    public init(
        series: [Reading],
        doses: [InsulinDose] = [],
        meals: [Meal] = [],
        thresholds: Thresholds,
        latest: Reading?,
        valueTint: Color,
        xDomain: ClosedRange<Date>,
        markerBucket: TimeInterval? = nil,
        selectedDate: Binding<Date?>
    ) {
        let span = xDomain.upperBound.timeIntervalSince(xDomain.lowerBound)
        self.series = downsample(series, maxPoints: maxLinePoints)
        if span > 7 * 86400 + 60 {
            self.segments = []
            self.envelope = glucoseEnvelope(series, over: xDomain, slices: span > 31 * 86400 ? Int(span / 86400) : 120)
        } else {
            self.segments = splitAtGaps(self.series, gap: max(30 * 60, 5 * span / Double(maxLinePoints)))
            self.envelope = []
        }
        self.doses = markerBucket.map { aggregateDoses(doses, bucket: $0) } ?? doses
        self.meals = markerBucket.map { aggregateMeals(meals, bucket: $0) } ?? meals
        self.thresholds = thresholds
        self.latest = latest
        self.valueTint = valueTint
        self.xDomain = xDomain
        self.markerBucket = markerBucket
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

            ForEach(segments.indices, id: \.self) { index in
                ForEach(segments[index], id: \.timestamp) { reading in
                    LineMark(
                        x: .value("Time", reading.timestamp),
                        y: .value("mmol/L", reading.value),
                        series: .value("Segment", index)
                    )
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: isMultiDay ? 1 : 2))
                    .foregroundStyle(.primary)
                }
            }

            ForEach(envelope.indices, id: \.self) { index in
                ForEach(envelope[index], id: \.start) { slice in
                    AreaMark(
                        x: .value("Time", slice.middle),
                        yStart: .value("Lowest", slice.low),
                        yEnd: .value("Highest", slice.high),
                        series: .value("Band", "range-\(index)")
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.primary.opacity(0.15))
                    LineMark(
                        x: .value("Time", slice.middle),
                        y: .value("mmol/L", slice.mean),
                        series: .value("Band", "mean-\(index)")
                    )
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .foregroundStyle(.primary)
                }
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
                    y: .value("mmol/L", doseBaseline(dose.kind))
                )
                .symbol(dose.kind == .bolus ? .circle : .diamond)
                .symbolSize(isHovered ? 110 : (dose.kind == .bolus ? 50 : 60))
                .foregroundStyle(dose.kind.tint)
                .annotation(position: .top, spacing: 1) {
                    if showsMarkerLabels {
                        Text(formatUnits(dose.units))
                            .font(.caption2)
                            .foregroundStyle(dose.kind.tint)
                    }
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
                    if showsMarkerLabels {
                        Text("\(formatGrams(meal.carbsGrams)) g")
                            .font(.caption2)
                            .foregroundStyle(mealTint)
                    }
                }
            }

            if let selected = nearestReading(to: selectedDate, in: series) {
                selectionMarks(for: selected, doses: hoveredDoses, meals: hoveredMeals)
            }
        }
        .chartXSelection(value: $selectedDate)
        .chartXScale(domain: xDomain)
        .chartXAxis {
            AxisMarks(values: xAxis.values) { _ in
                AxisGridLine()
                AxisTick()
                AxisValueLabel(format: xAxis.format, anchor: isMultiDay ? .topLeading : nil)
            }
        }
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

    private var span: TimeInterval { xDomain.upperBound.timeIntervalSince(xDomain.lowerBound) }

    private var isMultiDay: Bool { span > 86400 + 60 }

    private var hoverTolerance: TimeInterval { span / 60 }

    private var showsMarkerLabels: Bool { markerBucket == nil }

    private var xAxis: (values: AxisMarkValues, format: Date.FormatStyle) {
        let days = span / 86400
        let dayMonth = Date.FormatStyle.dateTime.day().month(.abbreviated)
        switch days {
        case ...0.26: return (.stride(by: .hour), .dateTime.hour())
        case ...0.51: return (.stride(by: .hour, count: 2), .dateTime.hour())
        case ...1.01: return (.stride(by: .hour, count: 4), .dateTime.hour())
        case ...7.01: return (.stride(by: .day), .dateTime.weekday(.abbreviated))
        case ...14.01: return (.stride(by: .day, count: 4), dayMonth)
        case ...30.01: return (.stride(by: .day, count: 7), dayMonth)
        default: return (.stride(by: .month), .dateTime.month(.abbreviated))
        }
    }

    private var pointTimeFormat: Date.FormatStyle {
        isMultiDay ? .dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute() : .dateTime.hour().minute()
    }

    /// Pooled markers stand for a whole bucket, so they are labelled by its date rather than a time.
    private var markerTimeFormat: Date.FormatStyle {
        switch markerBucket {
        case nil: .dateTime.hour().minute()
        case let bucket? where bucket < 86400: .dateTime.weekday(.abbreviated).hour()
        default: .dateTime.day().month(.abbreviated)
        }
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
                    Text(reading.timestamp, format: pointTimeFormat)
                        .foregroundStyle(.secondary)
                    ForEach(doses) { dose in
                        Text("\(dose.timestamp, format: markerTimeFormat) · \(formatUnits(dose.units)) u · \(dose.insulinName ?? dose.kind.label)\(dose.isManual ? " · entered" : "")")
                            .fontWeight(.semibold)
                            .foregroundStyle(dose.kind.tint)
                    }
                    ForEach(meals) { meal in
                        Text("\(meal.timestamp, format: markerTimeFormat) · \(formatGrams(meal.carbsGrams)) g · \(meal.summary)")
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
        let rows = doseRows + (meals.isEmpty ? 0 : 1)
        return rows == 0 ? 0 : 1.4 + Double(rows - 1) * rowHeight
    }

    /// Pooled Bolus and Basal markers share a bucket's midpoint, so Basal gets its own row.
    private var doseRows: Int {
        guard !doses.isEmpty else { return 0 }
        return markerBucket != nil && Set(doses.map(\.kind)).count > 1 ? 2 : 1
    }

    private var rowHeight: Double { 1.0 }

    private func doseBaseline(_ kind: InsulinKind) -> Double {
        let row = (meals.isEmpty ? 0 : 1) + (doseRows == 2 && kind == .basal ? 1 : 0)
        return yDomain.lowerBound + 0.35 + Double(row) * rowHeight
    }

    private var mealBaseline: Double { yDomain.lowerBound + 0.35 }
}

private let maxLinePoints = 600

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
