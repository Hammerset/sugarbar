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
    @AppStorage("panel.showsDetails") private var showsDetails = false
    @State private var headerHeight: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0
    @State private var copiedNote: String?

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
            if !attention.isEmpty {
                AttentionList(items: attention, onOpenMeal: onPlanMeal)
                    .font(.callout)
            }
            chart
            HStack(spacing: 6) {
                RangeSelector(selection: $window)
                CopyForClaudeButton(copied: copiedNote, onCopy: copyForClaude)
            }
            ForecastCaption(forecast: model.forecast, therapyComplete: model.settings.therapy.isComplete)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            details
            if showsDoseEntry {
                Divider()
                DoseEntrySection(model: model, isPresented: $showsDoseEntry)
                    .id(Self.doseEntryID)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var attention: [AttentionItem] {
        attentionItems(
            content: model.content,
            statusMessage: model.statusMessage,
            forecast: model.forecast,
            latest: model.latest,
            settings: model.settings,
            meals: model.meals,
            now: model.now,
            syncErrors: model.insulinSyncError.map { ["Glooko: \($0)"] } ?? []
        )
    }

    private var details: some View {
        let upcoming = upcomingMealPlans(model.meals, now: model.now)
        let suggestions = model.therapySuggestions
        return VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { showsDetails.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(glanceDetailsSummary(
                        readings: series,
                        thresholds: thresholds,
                        windowLabel: window.label,
                        suggestionCount: suggestions.count,
                        upcomingMealCount: upcoming.count
                    ))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(showsDetails ? 0 : -90))
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showsDetails {
                GlanceDetails(
                    windowLabel: window.label,
                    readings: series,
                    doses: model.chartDoses(window: window),
                    meals: model.chartMeals(window: window),
                    upcomingMeals: upcoming,
                    thresholds: thresholds,
                    showsInsulin: model.glookoAccountEmail != nil || !model.chartDoses(window: window).isEmpty,
                    suggestions: suggestions,
                    onAccept: model.acceptSuggestion,
                    onDismiss: model.dismissSuggestion,
                    onOpenMeal: onPlanMeal,
                    forecastReview: model.forecastReview
                )
                .font(.callout)
            }
        }
    }

    private func copyForClaude(includesQuestion: Bool) {
        let text = model.claudeSnapshot(window: window, includesQuestion: includesQuestion)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let note = includesQuestion ? "Copied with a question" : "Copied for Claude"
        withAnimation(.snappy(duration: 0.15)) { copiedNote = note }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            guard copiedNote == note else { return }
            withAnimation(.easeOut(duration: 0.3)) { copiedNote = nil }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            GlucoseReadout(content: model.content, size: 44)
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                ReadingAge(latest: model.latest)
                    .font(.callout)
                OnBoardLine(forecast: model.forecast)
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
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
            valueTint: model.content.tint,
            xDomain: window.interval(endingAt: model.now),
            markerBucket: window.markerBucket,
            selectedDate: $selectedDate
        )
    }

    private var footer: some View {
        VStack(spacing: 12) {
            Divider()
            HStack(spacing: 6) {
                QuickActionBar([
                    .logDose { showsDoseEntry.toggle() },
                    .logMeal(onLogMeal),
                    .planMeal(onPlanMeal),
                    .askClaude(onAskClaude),
                ])
                Menu {
                    Button("Copy for Claude") { copyForClaude(includesQuestion: false) }
                    Button("Copy for Claude with a Dose Question") { copyForClaude(includesQuestion: true) }
                    Divider()
                    Button("Settings…", action: onOpenSettings)
                    Divider()
                    Button("Quit Sugarbar") { NSApplication.shared.terminate(nil) }
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Settings")
                .accessibilityLabel("Settings")
            }
        }
        .padding([.horizontal, .bottom], Self.padding)
    }
}

/// Copies the Claude Snapshot of the selected range; the note confirms it over the range selector's row.
private struct CopyForClaudeButton: View {
    let copied: String?
    let onCopy: (_ includesQuestion: Bool) -> Void

    var body: some View {
        Button { onCopy(false) } label: {
            Image(systemName: copied == nil ? "doc.on.clipboard" : "checkmark")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(copied == nil ? Color.secondary : Color.green)
                .frame(width: 30, height: 26)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Copy this range for a Claude chat")
        .accessibilityLabel("Copy for Claude")
        .contextMenu {
            Button("Copy for Claude") { onCopy(false) }
            Button("Copy for Claude with a Dose Question") { onCopy(true) }
        }
        .overlay(alignment: .trailing) {
            if let copied {
                Text(copied)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background {
                        Capsule()
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                    }
                    .fixedSize()
                    .offset(x: -36)
                    .transition(.opacity)
                    .allowsHitTesting(false)
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
