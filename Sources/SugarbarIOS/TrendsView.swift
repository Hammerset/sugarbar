import SwiftUI
import SugarbarCore
import SugarbarUI

struct TrendsView: View {
    let model: GlucoseViewModel

    @State private var window: HistoryWindow = .fourHours
    @State private var selectedDate: Date?

    private var thresholds: Thresholds { model.thresholds }
    private var series: [Reading] { model.chartSeries(window: window) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    valueDisplay
                        .frame(maxWidth: .infinity, alignment: .center)

                    if let stateLine {
                        Text(stateLine)
                            .font(.subheadline)
                            .foregroundStyle(stateIsWarning ? .orange : .secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }

                    GlucoseHistoryChart(
                        series: series,
                        thresholds: thresholds,
                        latest: model.latest,
                        valueTint: model.content.tint,
                        xDomain: xDomain,
                        selectedDate: $selectedDate
                    )
                    windowPicker
                    timeInRangeCard

                    Text("Not a medical device — for information only.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)

                    Button("Sign Out", role: .destructive) {
                        model.signOut()
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(20)
            }
            .navigationTitle("Trends")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private var valueDisplay: some View {
        HStack(alignment: .center, spacing: 12) {
            if let text = model.content.text {
                Text(text)
                    .font(.system(size: 56, weight: .semibold, design: .rounded))
                    .foregroundStyle(model.content.tint)
            } else if let glyph = model.content.glyph {
                Image(systemName: glyph)
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(model.content.tint)
            }
            if let symbol = model.content.trendSymbol {
                Image(systemName: symbol)
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(model.content.tint)
            }
            if let latest = model.latest {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(formatAge(latest.age(at: context.date)))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 8)
            }
        }
    }

    private var stateIsWarning: Bool {
        if model.statusMessage != nil { return true }
        if case .stale = model.content { return true }
        return false
    }

    private var stateLine: String? {
        if let message = model.statusMessage { return message }
        switch model.content {
        case let .warmingUp(remaining):
            let minutes = max(1, Int(ceil(remaining / 60)))
            return "Sensor warming up — ready in \(minutes) min"
        case .stale:
            return "No Recent Data"
        case .empty:
            return "Waiting for data"
        case let .live(_, _, _, outOfRange):
            switch outOfRange {
            case .low: return "Below sensor range"
            case .high: return "Above sensor range"
            case nil: return nil
            }
        }
    }

    private var windowPicker: some View {
        Picker("Window", selection: $window) {
            ForEach(HistoryWindow.allCases) { window in
                Text("\(window.hours)h").tag(window)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    @ViewBuilder
    private var timeInRangeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Time in Range")
                .font(.headline)
            if let summary = timeInRange(series, thresholds: thresholds) {
                HStack(spacing: 0) {
                    timeInRangeStat(label: "Low", percent: summary.lowPercent, tint: Band.low.tint)
                    timeInRangeStat(label: "In Range", percent: summary.inRangePercent, tint: Band.inRange.tint)
                    timeInRangeStat(label: "High", percent: summary.highPercent, tint: Band.high.tint)
                }
            } else {
                Text("Not enough data yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func timeInRangeStat(label: String, percent: Double, tint: Color) -> some View {
        VStack(spacing: 4) {
            Text("\(Int(percent.rounded()))%")
                .font(.title2.bold())
                .foregroundStyle(tint)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var xDomain: ClosedRange<Date> {
        let end = model.now
        return end.addingTimeInterval(-Double(window.hours) * 3600)...end
    }
}
