import SwiftUI
import SugarbarCore
import SugarbarUI

struct TrendsView: View {
    let model: GlucoseViewModel

    @State private var window: HistoryWindow = .fourHours
    @State private var selectedDate: Date?
    @State private var showMealLog = false
    @State private var mealLogMode: MealEntryMode = .log
    @State private var showDoseLog = false
    @State private var showSettings = false
    @State private var askClaude: AskClaudeModel?
    @State private var showAskClaude = false
    @State private var sharedSnapshot: SharedSnapshot?
    @State private var copiedNote: String?

    private var thresholds: Thresholds { model.thresholds }
    private var series: [Reading] { model.chartSeries(window: window) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if !attention.isEmpty {
                        AttentionList(items: attention) { openMealLog(.plan) }
                            .font(.subheadline)
                    }
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
                    windowPicker
                    ForecastCaption(forecast: model.forecast, therapyComplete: model.settings.therapy.isComplete)
                        .font(.footnote)
                    QuickActionBar([
                        .logDose { showDoseLog = true },
                        .logMeal { openMealLog(.log) },
                        .planMeal { openMealLog(.plan) },
                        .askClaude {
                            askClaude = askClaude ?? model.makeAskClaudeModel()
                            showAskClaude = true
                        },
                    ])
                    GlanceDetails(
                        windowLabel: window.label,
                        readings: series,
                        doses: model.chartDoses(window: window),
                        meals: model.chartMeals(window: window),
                        upcomingMeals: upcomingMealPlans(model.meals, now: model.now),
                        thresholds: thresholds,
                        showsInsulin: model.isGlookoSignedIn || !model.chartDoses(window: window).isEmpty,
                        suggestions: model.therapySuggestions,
                        onAccept: model.acceptSuggestion,
                        onDismiss: model.dismissSuggestion,
                        onOpenMeal: { openMealLog(.plan) },
                        forecastReview: model.forecastReview
                    )
                    .font(.subheadline)
                    .padding(16)
                    .background(GlanceStyle.cardFill, in: RoundedRectangle(cornerRadius: 16))
                }
                .padding(20)
            }
            .overlay(alignment: .top) {
                if let copiedNote {
                    Text(copiedNote)
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .navigationTitle("Sugarbar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("Copy for Claude", systemImage: "doc.on.clipboard") { copyForClaude(includesQuestion: false) }
                        Button("Copy with a Dose Question", systemImage: "questionmark.bubble") { copyForClaude(includesQuestion: true) }
                        Button("Share…", systemImage: "square.and.arrow.up") {
                            sharedSnapshot = SharedSnapshot(text: model.claudeSnapshot(window: window))
                        }
                    } label: {
                        Label("Copy for Claude", systemImage: "doc.on.clipboard")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Settings", systemImage: "gearshape") { showSettings = true }
                }
            }
            .sheet(isPresented: $showSettings, onDismiss: model.reloadSettings) {
                SettingsScreen(model: model)
            }
            .sheet(isPresented: $showDoseLog) {
                DoseLogView(model: model)
            }
            .sheet(isPresented: $showMealLog) {
                MealLogView(model: model, mode: mealLogMode)
            }
            .sheet(item: $sharedSnapshot) { snapshot in
                ActivitySheet(text: snapshot.text)
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showAskClaude) {
                if let askClaude {
                    AskClaudeSheet(model: model, askModel: askClaude)
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 4) {
            GlucoseReadout(content: model.content, size: 56)
            HStack(spacing: 6) {
                ReadingAge(latest: model.latest)
                if model.forecast.map({ $0.insulinOnBoard >= 0.05 || $0.carbsOnBoard >= 0.5 }) == true {
                    Text("·")
                    OnBoardLine(forecast: model.forecast)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
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
            syncErrors: [model.insulinSyncError.map { "Glooko: \($0)" }, model.healthKitError].compactMap { $0 }
        )
    }

    private func copyForClaude(includesQuestion: Bool) {
        UIPasteboard.general.string = model.claudeSnapshot(window: window, includesQuestion: includesQuestion)
        let note = includesQuestion ? "Copied with a question" : "Copied for Claude"
        withAnimation(.snappy) { copiedNote = note }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            guard copiedNote == note else { return }
            withAnimation(.easeOut) { copiedNote = nil }
        }
    }

    private func openMealLog(_ mode: MealEntryMode) {
        mealLogMode = mode
        showMealLog = true
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
}

private struct SharedSnapshot: Identifiable {
    let id = UUID()
    let text: String
}

private struct ActivitySheet: UIViewControllerRepresentable {
    let text: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
