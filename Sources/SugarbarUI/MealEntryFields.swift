import SwiftUI
import SugarbarCore

/// A Meal being logged or edited: an optional photo and description for the Estimate, then the user's reviewed figure.
public struct MealDraft: Equatable {
    public var photoJPEG: Data?
    public var note: String
    public var estimate: MealEstimate?
    public var carbsGrams: Double
    public var summary: String
    public var timestamp: Date
    public private(set) var editing: Meal?

    public init() {
        photoJPEG = nil
        note = ""
        estimate = nil
        carbsGrams = 0
        summary = ""
        timestamp = Date()
        editing = nil
    }

    public init(editing meal: Meal) {
        self.init()
        carbsGrams = meal.carbsGrams
        summary = meal.summary
        timestamp = meal.timestamp
        editing = meal
    }

    public var canEstimate: Bool {
        photoJPEG != nil || !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var isValid: Bool { carbsGrams > 0 && carbsGrams <= maxMealCarbsGrams }

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
        if summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { summary = estimate.summary }
    }

    public func meal() -> Meal? {
        guard isValid else { return nil }
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return Meal(id: editing?.id ?? UUID(), timestamp: timestamp, carbsGrams: carbsGrams, summary: trimmed.isEmpty ? "Meal" : trimmed)
    }
}

public let maxMealCarbsGrams: Double = 500

/// The review rows shared by the Mac window and the iOS sheet.
public struct MealReviewFields: View {
    @Binding var draft: MealDraft

    public init(draft: Binding<MealDraft>) {
        _draft = draft
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
        }
        TextField("Description", text: $draft.summary)
        DatePicker("Time", selection: $draft.timestamp, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
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
    "\(meal.timestamp.formatted(.dateTime.day().month(.abbreviated).hour().minute())) · \(formatGrams(meal.carbsGrams)) g · \(meal.summary)"
}

/// The Meals editable from the log screens: the last two weeks, newest first.
public func recentMeals(_ meals: [Meal], now: Date = Date()) -> [Meal] {    meals.filter { $0.timestamp >= now.addingTimeInterval(-HistoryWindow.twoWeeks.duration) }
        .sorted { $0.timestamp > $1.timestamp }
}
