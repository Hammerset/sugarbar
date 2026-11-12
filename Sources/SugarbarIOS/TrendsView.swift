import SwiftUI
import SugarbarCore
import SugarbarUI

struct TrendsView: View {
    let model: GlucoseViewModel

    @State private var window: HistoryWindow = .fourHours
    @State private var selectedDate: Date?
    @State private var showGlookoSignIn = false
    @State private var showMealLog = false
    @State private var showDoseLog = false
    @State private var showClaudeKey = false
    @State private var showAlerts = false
    @State private var showTherapySettings = false

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
                        doses: model.chartDoses(window: window),
                        meals: model.chartMeals(window: window),
                        thresholds: thresholds,
                        latest: model.latest,
                        valueTint: model.content.tint,
                        xDomain: window.interval(endingAt: model.now),
                        markerBucket: window.markerBucket,
                        selectedDate: $selectedDate
                    )
                    windowPicker
                    timeInRangeCard
                    insulinCard
                    mealsCard

                    Text("Not a medical device — for information only.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)

                    Button("Therapy Settings") { showTherapySettings = true }
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
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Alerts", systemImage: "bell") { showAlerts = true }
                }
            }
            .sheet(isPresented: $showAlerts) {
                AlertSettingsView()
            }
            .sheet(isPresented: $showGlookoSignIn) {
                GlookoSignInView(model: model)
            }
            .sheet(isPresented: $showDoseLog) {
                DoseLogView(model: model)
            }
            .sheet(isPresented: $showMealLog) {
                MealLogView(model: model)
            }
            .sheet(isPresented: $showClaudeKey) {
                ClaudeAPIKeyView(model: model)
            }
            .sheet(isPresented: $showTherapySettings) {
                TherapySettingsView()
            }
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
                Text(window.label).tag(window)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    @ViewBuilder
    private var timeInRangeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Time in Range · \(window.label)")
                .font(.headline)
            TimeInRangeView(summary: timeInRange(series, thresholds: thresholds))
        }
    }

    @ViewBuilder
    private var insulinCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Insulin")
                    .font(.headline)
                Spacer()
                Button("Log Dose", systemImage: "syringe") { showDoseLog = true }
                    .buttonStyle(.bordered)
            }
            if model.isGlookoSignedIn || !model.chartDoses(window: window).isEmpty {
                insulinTotalsRow
            }
            if model.isGlookoSignedIn {
                if let error = model.insulinSyncError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                Button("Disconnect Glooko", role: .destructive) {
                    model.signOutGlooko()
                }
                .font(.footnote)
            } else {
                Text("Connect your Glooko account to see pen and logged doses on the graph.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Connect Glooko") { showGlookoSignIn = true }
                    .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private var mealsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Meals")
                .font(.headline)
            if model.hasClaudeAPIKey {
                Text("\(formatGrams(carbTotal(model.chartMeals(window: window)))) g carbs logged in the last \(window.label)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let error = model.healthKitError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                Button("Log Meal", systemImage: "camera") { showMealLog = true }
                    .buttonStyle(.borderedProminent)
                Button("Remove Claude API Key", role: .destructive) {
                    model.clearClaudeAPIKey()
                }
                .font(.footnote)
            } else {
                Text("Add a Claude API key to log meals from a photo. Claude estimates the carbs, you confirm them, and the meal is saved to Apple Health.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Add Claude API Key") { showClaudeKey = true }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var insulinTotalsRow: some View {
        let totals = insulinTotals(model.chartDoses(window: window))
        return HStack(spacing: 0) {
            insulinStat(label: "Bolus", units: totals.bolus, tint: InsulinKind.bolus.tint)
            insulinStat(label: "Basal", units: totals.basal, tint: InsulinKind.basal.tint)
        }
    }

    private func insulinStat(label: String, units: Double, tint: Color) -> some View {
        VStack(spacing: 4) {
            Text("\(formatUnits(units)) u")
                .font(.title2.bold())
                .foregroundStyle(tint)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
