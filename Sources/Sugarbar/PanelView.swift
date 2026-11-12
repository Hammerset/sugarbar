import SwiftUI
import SugarbarCore
import SugarbarUI

struct PanelView: View {
    let model: BarViewModel
    var onOpenSettings: () -> Void = {}
    var onAskClaude: () -> Void = {}
    var onLogMeal: () -> Void = {}
    var onPlanMeal: () -> Void = {}
    @State private var window: HistoryWindow = .fourHours
    @State private var selectedDate: Date?
    @State private var showsDoseEntry = false

    private var thresholds: Thresholds { model.thresholds }
    private var series: [Reading] { model.chartSeries(window: window) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            OnBoardSummary(forecast: model.forecast, therapyComplete: model.settings.therapy.isComplete)
                .font(.caption)
            ForEach(model.therapySuggestions, id: \.quantity) { suggestion in
                TherapySuggestionRow(
                    suggestion: suggestion,
                    onAccept: { model.acceptSuggestion(suggestion) },
                    onDismiss: { model.dismissSuggestion(suggestion) }
                )
                .font(.caption)
            }
            chart
            insulinLine
            ForEach(activeMealPlans(model.meals, now: model.now)) { meal in
                Button(mealSummaryLine(meal), action: onPlanMeal)
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(meal.isPlanned ? Color.secondary : Color.orange)
                    .lineLimit(2)
            }
            if showsDoseEntry {
                DoseEntrySection(model: model, isPresented: $showsDoseEntry)
            }
            rangePicker
            TimeInRangeView(summary: timeInRange(series, thresholds: thresholds))
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                headerValue
                if let symbol = model.content.trendSymbol {
                    Image(systemName: symbol)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(valueTint)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let latest = model.latest {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(formatAge(latest.age(at: context.date)))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                if let state = stateLine {
                    Text(state)
                        .font(.caption)
                        .foregroundStyle(stateIsWarning ? .orange : .secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var headerValue: some View {
        if let text = model.content.text {
            Text(text)
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .foregroundStyle(valueTint)
        } else if let glyph = model.content.glyph {
            Image(systemName: glyph)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(valueTint)
        }
    }

    private var chart: some View {
        GlucoseHistoryChart(
            series: series,
            doses: model.chartDoses(window: window),
            meals: model.chartMeals(window: window),
            forecast: model.chartForecast(window: window),
            thresholds: thresholds,
            latest: model.latest,
            valueTint: valueTint,
            xDomain: window.interval(endingAt: model.now),
            markerBucket: window.markerBucket,
            selectedDate: $selectedDate
        )
    }

    @ViewBuilder
    private var insulinLine: some View {
        if let error = model.insulinSyncError {
            Text("Glooko: \(error)")
                .font(.caption)
                .foregroundStyle(.orange)
        } else if model.glookoAccountEmail != nil || !model.chartDoses(window: window).isEmpty {
            let totals = insulinTotals(model.chartDoses(window: window))
            Text("Insulin \(window.label) · bolus \(formatUnits(totals.bolus)) u · basal \(formatUnits(totals.basal)) u")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var rangePicker: some View {
        Picker("Range", selection: $window) {
            ForEach(HistoryWindow.allCases) { window in
                Text(window.label).tag(window)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Not a medical device — for information only.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            HStack(spacing: 12) {
                Button("Log Dose", systemImage: "syringe") { showsDoseEntry.toggle() }
                Button("Plan Meal", systemImage: "list.bullet.clipboard", action: onPlanMeal)
                Button("Log Meal", systemImage: "fork.knife", action: onLogMeal)
            }
            .buttonStyle(.borderless)
            Button("Ask Claude", systemImage: "bubble.left.and.text.bubble.right", action: onAskClaude)
                .buttonStyle(.borderless)
            HStack {
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                        .font(.body)
                }
                .buttonStyle(.borderless)
                .help("Settings")
                .accessibilityLabel("Settings")
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
    }

    private var valueTint: Color { model.content.tint }

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
}
