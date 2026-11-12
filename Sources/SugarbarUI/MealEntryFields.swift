import SwiftUI
import SugarbarCore

public enum MealEntryMode: Hashable {
    case plan
    case log
}

/// A Meal being planned, logged or edited: an optional photo and description for the Estimate, the user's
/// reviewed figures, and while planning the dose the user settled on.
public struct MealDraft: Equatable {
    public var photoJPEG: Data?
    public var note: String
    public var estimate: MealEstimate?
    public var carbsGrams: Double
    public var summary: String
    public var timestamp: Date
    public var estimatedCarbsGrams: Double?
    public var fatGrams: Double?
    public var proteinGrams: Double?
    public var energyKcal: Double?
    public var absorption: AbsorptionSpeed?
    public var plannedUnits: Double
    public var splitsDose: Bool
    public var nowUnits: Double
    public var takenUnits: Double
    public var suggestedUnits: Double?
    public var strategy: MealStrategy?
    public private(set) var hasEditedUnits: Bool
    public private(set) var editing: Meal?

    public init() {
        photoJPEG = nil
        note = ""
        estimate = nil
        carbsGrams = 0
        summary = ""
        timestamp = Date()
        estimatedCarbsGrams = nil
        fatGrams = nil
        proteinGrams = nil
        energyKcal = nil
        absorption = nil
        plannedUnits = 0
        splitsDose = false
        nowUnits = 0
        takenUnits = 0
        suggestedUnits = nil
        strategy = nil
        hasEditedUnits = false
        editing = nil
    }

    public init(editing meal: Meal) {
        self.init()
        carbsGrams = meal.carbsGrams
        summary = meal.summary
        timestamp = meal.timestamp
        estimatedCarbsGrams = meal.estimatedCarbsGrams
        fatGrams = meal.fatGrams
        proteinGrams = meal.proteinGrams
        energyKcal = meal.energyKcal
        absorption = meal.absorption
        if let plan = meal.plan {
            plannedUnits = plan.units
            takenUnits = plan.takenUnits
            suggestedUnits = plan.suggestedUnits
            splitsDose = plan.firstUnits != nil
            nowUnits = plan.firstUnits ?? plan.units
            hasEditedUnits = true
        }
        editing = meal
    }

    /// "I'm eating now": the planned Meal becomes the eaten one, timed now, ready for a fresh look at what is on the plate.
    public init(eating meal: Meal, now: Date = Date()) {
        self.init(editing: meal)
        timestamp = now
        note = meal.summary
    }

    /// After a save mid-plan (logging part of the dose), so later saves update the same Meal.
    public mutating func markSaved(_ meal: Meal) {
        editing = meal
    }

    public var canEstimate: Bool {
        photoJPEG != nil || !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var isValid: Bool { carbsGrams > 0 && carbsGrams <= maxMealCarbsGrams }

    public var isEditingPlan: Bool { editing?.isPlanned == true }

    /// False when the data is not an image ImageIO can read.
    public mutating func setPhoto(_ imageData: Data) -> Bool {
        guard let jpeg = mealPhotoJPEG(from: imageData) else { return false }
        photoJPEG = jpeg
        estimate = nil
        return true
    }

    public mutating func apply(_ estimate: MealEstimate) {
        self.estimate = estimate
        carbsGrams = estimate.carbsGrams.rounded()
        estimatedCarbsGrams = estimate.carbsGrams
        fatGrams = estimate.fatGrams
        proteinGrams = estimate.proteinGrams
        energyKcal = estimate.energyKcal
        absorption = estimate.absorption
        if summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { summary = estimate.summary }
    }

    /// Follows the app's calculation until the user types their own amount.
    public mutating func adoptSuggestion(_ units: Double?) {
        suggestedUnits = units
        guard !hasEditedUnits else { return }
        plannedUnits = units ?? 0
        if !splitsDose { nowUnits = plannedUnits }
    }

    public mutating func setPlannedUnits(_ units: Double) {
        plannedUnits = max(0, units)
        hasEditedUnits = true
        if !splitsDose { nowUnits = plannedUnits }
    }

    public mutating func apply(_ strategy: MealStrategy, penStep: Double) {
        self.strategy = strategy
        if let split = strategy.split, takenUnits == 0 {
            splitsDose = true
            let total = max(plannedUnits, 0)
            let share = split.nowUnits / max(split.nowUnits + split.laterUnits, 0.001)
            nowUnits = roundDown(total * share, toStep: penStep)
        }
    }

    /// What "Log dose" prefills: the rest of the plan once some is logged, the first part of a split, or the whole dose.
    public var unitsToLogNow: Double {
        if takenUnits > 0 { return max(0, plannedUnits - takenUnits) }
        return splitsDose ? min(nowUnits, plannedUnits) : plannedUnits
    }

    public var remainingUnits: Double { max(0, plannedUnits - takenUnits) }

    private var laterNote: String? {
        guard splitsDose else { return nil }
        let later = takenUnits > 0 ? remainingUnits : max(0, plannedUnits - nowUnits)
        guard later > 0 else { return nil }
        let when = strategy?.split?.laterAfterMinutes.map { "about \($0) min after starting to eat" } ?? "later"
        return "\(formatUnits(later)) u \(when)"
    }

    public func meal(state: MealState) -> Meal? {
        guard isValid else { return nil }
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let plan: MealPlan? = plannedUnits > 0 || takenUnits > 0
            ? MealPlan(
                carbsGrams: editing?.plan?.carbsGrams ?? carbsGrams,
                units: plannedUnits,
                takenUnits: takenUnits,
                suggestedUnits: suggestedUnits,
                firstUnits: splitsDose ? min(nowUnits, plannedUnits) : nil,
                strategy: strategy?.summaryLine ?? editing?.plan?.strategy,
                laterNote: laterNote
            )
            : editing?.plan
        return Meal(
            id: editing?.id ?? UUID(),
            timestamp: timestamp,
            carbsGrams: carbsGrams,
            summary: trimmed.isEmpty ? (fallback.isEmpty ? "Meal" : String(fallback.prefix(80))) : trimmed,
            estimatedCarbsGrams: estimatedCarbsGrams,
            fatGrams: fatGrams,
            proteinGrams: proteinGrams,
            energyKcal: energyKcal,
            absorption: absorption,
            state: state,
            plan: plan
        )
    }
}

public let maxMealCarbsGrams: Double = 500

/// The review rows shared by the Mac window and the iOS sheet.
public struct MealReviewFields: View {
    @Binding var draft: MealDraft
    let mode: MealEntryMode

    public init(draft: Binding<MealDraft>, mode: MealEntryMode = .log) {
        _draft = draft
        self.mode = mode
    }

    public var body: some View {
        LabeledContent("Carbs") {
            HStack {
                TextField("0", value: $draft.carbsGrams, format: .number.precision(.fractionLength(0)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 70)
                    .decimalKeyboard()
                Text("g").foregroundStyle(.secondary)
            }
            .font(.title3.weight(.semibold))
        }
        if let estimated = draft.estimatedCarbsGrams, formatGrams(estimated) != formatGrams(draft.carbsGrams) {
            Text("Claude estimated \(formatGrams(estimated)) g")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        if let macros = macroLine(fat: draft.fatGrams, protein: draft.proteinGrams, energy: draft.energyKcal, absorption: draft.absorption) {
            Text(macros.prefix(1).uppercased() + macros.dropFirst())
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        TextField("Description", text: $draft.summary)
        DatePicker(
            mode == .plan ? "Eating at" : "Time",
            selection: $draft.timestamp,
            in: ...Date().addingTimeInterval(mode == .plan ? 12 * 3600 : 0),
            displayedComponents: [.date, .hourAndMinute]
        )
    }

    public static let note = "Claude's Estimate is a starting point — check the grams before saving. Not a medical device."
}

public struct MealEstimateDetails: View {
    let estimate: MealEstimate

    public init(estimate: MealEstimate) {
        self.estimate = estimate
    }

    public var body: some View {
        ForEach(estimate.items, id: \.self) { item in
            Text(item)
        }
        if !estimate.assumptions.isEmpty {
            Text("Assumed: " + estimate.assumptions.joined(separator: "; "))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        Text("Confidence: \(estimate.confidence)")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}

public func mealSummaryLine(_ meal: Meal) -> String {
    var line = "\(meal.timestamp.formatted(.dateTime.day().month(.abbreviated).hour().minute())) · \(formatGrams(meal.carbsGrams)) g · \(meal.summary)"
    if meal.isPlanned { line = "Planned · " + line }
    if let plan = meal.plan, plan.remainingUnits > 0, plan.takenUnits > 0 {
        line += " · \(formatUnits(plan.remainingUnits)) u still to take" + (plan.laterNote.map { " (\($0))" } ?? "")
    }
    return line
}

/// Plans not eaten yet and Meals with part of a split dose still to take, from the last 6 hours on.
public func activeMealPlans(_ meals: [Meal], now: Date = Date()) -> [Meal] {
    let since = now.addingTimeInterval(-6 * 3600)
    return recentMeals(meals, now: now).filter { meal in
        guard meal.timestamp >= since else { return false }
        if meal.isPlanned { return true }
        guard let plan = meal.plan else { return false }
        return plan.takenUnits > 0 && plan.remainingUnits > 0
    }
}

/// The Meals editable from the log screens: Meal Plans and the last two weeks of eaten Meals, newest first.
public func recentMeals(_ meals: [Meal], now: Date = Date()) -> [Meal] {
    meals.filter { $0.timestamp >= now.addingTimeInterval(-HistoryWindow.twoWeeks.duration) }
        .sorted { ($0.isPlanned ? 1 : 0, $0.timestamp) > ($1.isPlanned ? 1 : 0, $1.timestamp) }
}
