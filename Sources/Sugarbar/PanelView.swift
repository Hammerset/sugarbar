import SwiftUI
import SugarbarCore
import SugarbarUI

struct PanelView: View {
    private static let width: CGFloat = 360
    private static let padding: CGFloat = 16
    private static let doseEntryID = "doseEntry"

    let model: BarViewModel
    var maxHeight: CGFloat = 720
    var onOpenSettings: () -> Void = {}
    var onAskClaude: () -> Void = {}
    var onLogMeal: () -> Void = {}
    var onPlanMeal: () -> Void = {}
    @State private var window: HistoryWindow = .fourHours
    @State private var selectedDate: Date?
    @State private var showsDoseEntry = false
    @State private var headerHeight: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0

    private var thresholds: Thresholds { model.thresholds }
    private var series: [Reading] { model.chartSeries(window: window) }
    private var maxContentHeight: CGFloat { max(maxHeight - headerHeight - footerHeight, 160) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding([.horizontal, .top], Self.padding)
                .padding(.bottom, 12)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    content
                        .padding(.horizontal, Self.padding)
                        .padding(.bottom, Self.padding)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(contentHeight, maxContentHeight))
                .onChange(of: showsDoseEntry) { _, shows in
                    guard shows else { return }
                    Task { @MainActor in
                        withAnimation { proxy.scrollTo(Self.doseEntryID, anchor: .bottom) }
                    }
                }
            }
            footer
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
        }
        .frame(width: Self.width)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            OnBoardSummary(forecast: model.forecast, therapyComplete: model.settings.therapy.isComplete)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            chart
            insulinTotalsLine
            rangePicker
            TimeInRangeView(summary: timeInRange(series, thresholds: thresholds))
            contextualRows
            if showsDoseEntry {
                Divider()
                DoseEntrySection(model: model, isPresented: $showsDoseEntry)
                    .id(Self.doseEntryID)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var contextualRows: some View {
        ForEach(model.therapySuggestions, id: \.quantity) { suggestion in
            TherapySuggestionRow(
                suggestion: suggestion,
                onAccept: { model.acceptSuggestion(suggestion) },
                onDismiss: { model.dismissSuggestion(suggestion) }
            )
            .font(.caption)
        }
        ForEach(activeMealPlans(model.meals, now: model.now)) { meal in
            Button(action: onPlanMeal) {
                Text(mealSummaryLine(meal))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(meal.isPlanned ? Color.secondary : Color.orange)
        }
        if let error = model.insulinSyncError {
            Text("Glooko: \(error)")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
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
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
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
    private var insulinTotalsLine: some View {
        let doses = model.chartDoses(window: window)
        if model.glookoAccountEmail != nil || !doses.isEmpty {
            let totals = insulinTotals(doses)
            Text("Insulin \(window.label) · bolus \(formatUnits(totals.bolus)) u · basal \(formatUnits(totals.basal)) u")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var rangePicker: some View {
        RangeSelector(selection: $window)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text("Not a medical device — for information only.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    footerAction("Log Dose", systemImage: "syringe") { showsDoseEntry.toggle() }
                    footerAction("Log Meal", systemImage: "fork.knife", action: onLogMeal)
                }
                GridRow {
                    footerAction("Plan Meal", systemImage: "list.bullet.clipboard", action: onPlanMeal)
                    footerAction("Ask Claude", systemImage: "bubble.left.and.text.bubble.right", action: onAskClaude)
                }
            }
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
        .padding([.horizontal, .bottom], Self.padding)
    }

    private func footerAction(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage).frame(width: 20)
            }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
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

/// A segmented Picker's NSSegmentedControl won't shrink below its segments and overflowed the panel.
private struct RangeSelector: View {
    @Binding var selection: HistoryWindow
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(HistoryWindow.allCases) { option in
                let isSelected = option == selection
                Button { selection = option } label: {
                    Text(option.label)
                        .font(.callout.monospacedDigit())
                        .fontWeight(isSelected ? .semibold : .regular)
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity, minHeight: 22)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(colorScheme == .dark ? Color.white.opacity(0.22) : Color.white)
                                    .shadow(color: .black.opacity(0.15), radius: 0.5, y: 0.5)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Range")
    }
}
