import SwiftUI
import SugarbarCore

/// The Suggested Dose, Claude's strategy and the dose the user settles on, shared by the Mac window and the iOS sheet.
public struct MealPlanSections: View {
    @Binding var draft: MealDraft
    let suggestion: DoseSuggestion
    let pendingTherapySuggestions: [TherapySuggestion]
    let penStep: Double
    let canAskClaude: Bool
    let isLoadingStrategy: Bool
    let strategyError: String?
    let onRequestStrategy: () -> Void
    let onLogDose: () -> Void
    let onSavePlan: () -> Void
    let onOpenTherapySettings: () -> Void

    public init(
        draft: Binding<MealDraft>,
        suggestion: DoseSuggestion,
        pendingTherapySuggestions: [TherapySuggestion] = [],
        penStep: Double,
        canAskClaude: Bool,
        isLoadingStrategy: Bool,
        strategyError: String?,
        onRequestStrategy: @escaping () -> Void,
        onLogDose: @escaping () -> Void,
        onSavePlan: @escaping () -> Void,
        onOpenTherapySettings: @escaping () -> Void
    ) {
        _draft = draft
        self.suggestion = suggestion
        self.pendingTherapySuggestions = pendingTherapySuggestions
        self.penStep = penStep
        self.canAskClaude = canAskClaude
        self.isLoadingStrategy = isLoadingStrategy
        self.strategyError = strategyError
        self.onRequestStrategy = onRequestStrategy
        self.onLogDose = onLogDose
        self.onSavePlan = onSavePlan
        self.onOpenTherapySettings = onOpenTherapySettings
    }

    public var body: some View {
        Section {
            SuggestedDoseRows(suggestion: suggestion)
            ForEach(pendingTherapySuggestions, id: \.quantity) { pending in
                Label {
                    Text("Not used yet: " + pending.text)
                } icon: {
                    Image(systemName: "lightbulb").foregroundStyle(.orange)
                }
                .font(.footnote)
            }
            if !pendingTherapySuggestions.isEmpty || suggestion.withheldReasons.contains(.noTherapySettings) {
                Button("Open Therapy Settings", action: onOpenTherapySettings)
            }
        } header: {
            Text("Suggested Dose")
        } footer: {
            Text(Self.note)
        }
        .onAppear { draft.adoptSuggestion(suggestion.dose?.units) }
        .onChange(of: suggestion) { _, new in draft.adoptSuggestion(new.dose?.units) }

        Section {
            if canAskClaude {
                HStack {
                    Button(draft.strategy == nil ? "Get Strategy from Claude" : "Ask Again", action: onRequestStrategy)
                        .disabled(isLoadingStrategy || !draft.isValid)
                    if isLoadingStrategy { ProgressView().controlSize(.small) }
                }
            } else {
                Text("Add a Claude API key to get a strategy for when and how to take the dose.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let strategyError {
                Text(strategyError)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if let strategy = draft.strategy {
                MealStrategyRows(strategy: strategy, appUnits: suggestion.dose?.units)
            }
        } header: {
            Text("Strategy")
        }

        Section {
            unitsRow("Dose", value: Binding(get: { draft.plannedUnits }, set: { draft.setPlannedUnits($0) }))
            if let strategy = draft.strategy, let claude = strategy.recommendedUnits, strategy.differs(from: suggestion.dose?.units) {
                HStack {
                    if let app = suggestion.dose?.units {
                        Button("Use app's \(formatUnits(app)) u") { draft.setPlannedUnits(app) }
                    }
                    Button("Use Claude's \(formatUnits(claude)) u") { draft.setPlannedUnits(claude) }
                }
                .buttonStyle(.bordered)
            }
            Toggle("Split the dose", isOn: $draft.splitsDose)
                .disabled(draft.takenUnits > 0)
            if draft.splitsDose && draft.takenUnits == 0 {
                unitsRow("Now", value: $draft.nowUnits)
                LabeledContent("Later", value: "\(formatUnits(max(0, draft.plannedUnits - draft.nowUnits))) u")
            }
            if draft.takenUnits > 0 {
                LabeledContent("Logged so far", value: "\(formatUnits(draft.takenUnits)) u")
            }
            HStack {
                Button(draft.unitsToLogNow > 0 ? "Log \(formatUnits(draft.unitsToLogNow)) u Now…" : "Log Dose…", action: onLogDose)
                    .disabled(draft.unitsToLogNow <= 0)
                Spacer()
                Button(draft.isEditingPlan ? "Save Plan" : "Save as Plan", action: onSavePlan)
                    .disabled(!draft.isValid)
            }
        } header: {
            Text("Your Dose")
        } footer: {
            Text("Nothing counts as taken until you log the dose. Log the first part of a split now; the rest shows as a reminder on the plan.")
        }
    }

    private func unitsRow(_ label: String, value: Binding<Double>) -> some View {
        LabeledContent(label) {
            HStack {
                TextField("0", value: value, format: .number.precision(.fractionLength(0...1)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 60)
                    .decimalKeyboard()
                Text("u").foregroundStyle(.secondary)
                Stepper(label, value: value, in: 0...maxManualDoseUnits, step: penStep)
                    .labelsHidden()
            }
        }
    }

    public static let note = "The app's calculation from your carb ratio, insulin sensitivity and target. Check every number; you decide. Not a medical device."
}

/// The parts of the app's calculation, or why there is none.
public struct SuggestedDoseRows: View {
    let suggestion: DoseSuggestion

    public init(suggestion: DoseSuggestion) {
        self.suggestion = suggestion
    }

    public var body: some View {
        switch suggestion {
        case let .suggested(dose):
            LabeledContent("Suggested") {
                Text("\(formatUnits(dose.units)) u")
                    .font(.title3.weight(.semibold))
            }
            part("Meal", "\(formatGrams(dose.carbsGrams)) g ÷ \(number(dose.carbRatio)) g/u", dose.mealUnits)
            part("Correction", "(\(formatMmolPerL(dose.currentGlucose)) − \(formatMmolPerL(dose.targetGlucose))) ÷ \(number(dose.insulinSensitivity))", dose.correctionUnits)
            part("Insulin on board", "of \(String(format: "%.1f", dose.insulinOnBoard)) u", -dose.insulinOnBoardDeduction)
            Text("Using your Therapy Settings: carb ratio \(number(dose.carbRatio)) g per unit, insulin sensitivity \(number(dose.insulinSensitivity)) mmol/L per unit, target \(formatMmolPerL(dose.targetGlucose)).")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(roundingLine(dose))
                .font(.footnote)
                .foregroundStyle(dose.wasCapped ? .orange : .secondary)
        case let .withheld(reasons):
            ForEach(reasons, id: \.message) { reason in
                Text(reason.message)
                    .foregroundStyle(reason == .glucoseLow ? .orange : .secondary)
            }
        }
    }

    private func part(_ label: String, _ detail: String, _ units: Double) -> some View {
        LabeledContent {
            Text(String(format: "%+.1f u", units)).monospacedDigit()
        } label: {
            Text(label)
            Text(detail)
        }
    }

    private func roundingLine(_ dose: SuggestedDose) -> String {
        var line = "\(String(format: "%.1f", dose.unroundedUnits)) u rounded down to the \(formatUnits(dose.penStep)) u pen step."
        if dose.wasCapped { line += " Capped at your maximum of \(formatUnits(dose.maxSingleDose)) u." }
        return line
    }

    private func number(_ value: Double) -> String {
        value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }
}

/// Claude's strategy, with its amount beside the app's when the two differ.
public struct MealStrategyRows: View {
    let strategy: MealStrategy
    let appUnits: Double?

    public init(strategy: MealStrategy, appUnits: Double?) {
        self.strategy = strategy
        self.appUnits = appUnits
    }

    public var body: some View {
        if let plainText = strategy.plainText {
            Text(plainText)
        } else {
            if let recommended = strategy.recommendedUnits, strategy.differs(from: appUnits) {
                HStack(alignment: .top) {
                    amount("App's calculation", appUnits.map { "\(formatUnits($0)) u" } ?? "none")
                    amount("Claude recommends", "\(formatUnits(recommended)) u")
                }
                if let reason = strategy.differenceReason {
                    Text(reason).font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let timing = strategy.timing {
                row("syringe", timing + preBolusSuffix)
            }
            if let split = strategy.split {
                row("arrow.triangle.branch", "Split: \(formatUnits(split.nowUnits)) u now, \(formatUnits(split.laterUnits)) u " + (split.laterAfterMinutes.map { "about \($0) min after starting to eat" } ?? "later") + (split.reason.map { ". \($0)" } ?? ""))
            }
            ForEach(strategy.watchFor, id: \.self) { item in
                row("eye", item)
            }
            if let recheck = strategy.recheckAfterMinutes {
                row("clock", "Check glucose again about \(recheck) min after starting to eat.")
            }
            ForEach(strategy.cautions, id: \.self) { caution in
                row("exclamationmark.triangle", caution, tint: .orange)
            }
        }
    }

    private var preBolusSuffix: String {
        guard let minutes = strategy.preBolusMinutes else { return "" }
        if minutes > 0 { return " (\(minutes) min before eating)" }
        if minutes < 0 { return " (\(-minutes) min after starting to eat)" }
        return " (at the first bite)"
    }

    private func amount(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ symbol: String, _ text: String, tint: Color = .secondary) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
    }
}
