import Foundation

public enum MealState: String, Codable, Sendable {
    case planned
    case eaten
}

/// How fast a meal's carbs are likely to reach the blood, from its fat, protein, fibre and food type.
public enum AbsorptionSpeed: String, Codable, Sendable, CaseIterable {
    case fast
    case medium
    case slow

    public var label: String {
        switch self {
        case .fast: "fast"
        case .medium: "medium"
        case .slow: "slow"
        }
    }
}

/// The dose the user settled on while planning a Meal, and how much of it they have logged so far.
public struct MealPlan: Equatable, Sendable, Codable {
    /// The carbs the dose was planned for, which may differ from what was eaten.
    public var carbsGrams: Double
    public var units: Double
    public var takenUnits: Double
    /// The app's Suggested Dose at planning time, when there was one.
    public var suggestedUnits: Double?
    /// The first part of a split dose; nil when the dose is taken in one go.
    public var firstUnits: Double?
    public var strategy: String?
    /// When to take what is left of a split dose.
    public var laterNote: String?

    public init(
        carbsGrams: Double,
        units: Double,
        takenUnits: Double = 0,
        suggestedUnits: Double? = nil,
        firstUnits: Double? = nil,
        strategy: String? = nil,
        laterNote: String? = nil
    ) {
        self.carbsGrams = carbsGrams
        self.units = units
        self.takenUnits = takenUnits
        self.suggestedUnits = suggestedUnits
        self.firstUnits = firstUnits
        self.strategy = strategy
        self.laterNote = laterNote
    }

    public var remainingUnits: Double { max(0, units - takenUnits) }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        carbsGrams = try container.decodeIfPresent(Double.self, forKey: .carbsGrams) ?? 0
        units = try container.decodeIfPresent(Double.self, forKey: .units) ?? 0
        takenUnits = try container.decodeIfPresent(Double.self, forKey: .takenUnits) ?? 0
        suggestedUnits = try container.decodeIfPresent(Double.self, forKey: .suggestedUnits)
        firstUnits = try container.decodeIfPresent(Double.self, forKey: .firstUnits)
        strategy = try container.decodeIfPresent(String.self, forKey: .strategy)
        laterNote = try container.decodeIfPresent(String.self, forKey: .laterNote)
    }
}

/// One Meal: the carbs the user confirmed after reviewing Claude's Estimate, or a Meal Plan not eaten yet.
public struct Meal: Equatable, Sendable, Codable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let carbsGrams: Double
    public let summary: String
    /// Claude's figure before the user's review, when there was an Estimate.
    public let estimatedCarbsGrams: Double?
    public let fatGrams: Double?
    public let proteinGrams: Double?
    public let energyKcal: Double?
    public let absorption: AbsorptionSpeed?
    public let state: MealState
    public let plan: MealPlan?

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        carbsGrams: Double,
        summary: String,
        estimatedCarbsGrams: Double? = nil,
        fatGrams: Double? = nil,
        proteinGrams: Double? = nil,
        energyKcal: Double? = nil,
        absorption: AbsorptionSpeed? = nil,
        state: MealState = .eaten,
        plan: MealPlan? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.carbsGrams = carbsGrams
        self.summary = summary
        self.estimatedCarbsGrams = estimatedCarbsGrams
        self.fatGrams = fatGrams
        self.proteinGrams = proteinGrams
        self.energyKcal = energyKcal
        self.absorption = absorption
        self.state = state
        self.plan = plan
    }

    public var isEaten: Bool { state == .eaten }
    public var isPlanned: Bool { state == .planned }

    /// Meals saved before planning existed carry only id, time, carbs and summary, and were eaten.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        carbsGrams = try container.decode(Double.self, forKey: .carbsGrams)
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        estimatedCarbsGrams = try container.decodeIfPresent(Double.self, forKey: .estimatedCarbsGrams)
        fatGrams = try container.decodeIfPresent(Double.self, forKey: .fatGrams)
        proteinGrams = try container.decodeIfPresent(Double.self, forKey: .proteinGrams)
        energyKcal = try container.decodeIfPresent(Double.self, forKey: .energyKcal)
        absorption = (try? container.decodeIfPresent(AbsorptionSpeed.self, forKey: .absorption)) ?? nil
        state = (try? container.decodeIfPresent(MealState.self, forKey: .state)) ?? .eaten
        plan = try? container.decodeIfPresent(MealPlan.self, forKey: .plan)
    }
}

public func eatenMeals(_ meals: [Meal]) -> [Meal] {
    meals.filter(\.isEaten)
}

public func plannedMeals(_ meals: [Meal]) -> [Meal] {
    meals.filter(\.isPlanned)
}

/// Eaten Meals in the window; a Meal Plan never shows as eaten.
public func meals(_ meals: [Meal], within window: HistoryWindow, of now: Date) -> [Meal] {
    let cutoff = now.addingTimeInterval(-window.duration)
    return meals.filter { $0.isEaten && $0.timestamp >= cutoff && $0.timestamp <= now }
}

/// Every meal within `tolerance` of a hovered date, oldest first.
public func meals(near date: Date, in meals: [Meal], tolerance: TimeInterval) -> [Meal] {
    meals
        .filter { abs($0.timestamp.timeIntervalSince(date)) <= tolerance }
        .sorted { $0.timestamp < $1.timestamp }
}

public func carbTotal(_ meals: [Meal]) -> Double {
    meals.reduce(0) { $0 + ($1.isEaten ? $1.carbsGrams : 0) }
}

public func formatGrams(_ grams: Double) -> String {
    String(format: "%.0f", grams.rounded())
}

/// "fat 20 g · protein 31 g · 640 kcal", leaving out what is unknown; nil when nothing is.
public func macroLine(fat: Double?, protein: Double?, energy: Double?, absorption: AbsorptionSpeed? = nil) -> String? {
    var parts: [String] = []
    if let fat { parts.append("fat \(formatGrams(fat)) g") }
    if let protein { parts.append("protein \(formatGrams(protein)) g") }
    if let energy { parts.append("\(formatGrams(energy)) kcal") }
    if let absorption { parts.append("\(absorption.label) absorption") }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
}

public let anthropicKeychainServicePrefix = "no.ignite.sugarbar.anthropic"

public func anthropicAPIKey(fromEnvironment environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
    environment["SUGARBAR_ANTHROPIC_API_KEY"]
}
