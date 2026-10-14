import Foundation

/// One logged meal: the carbs the user confirmed after reviewing Claude's estimate.
public struct Meal: Equatable, Sendable, Codable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let carbsGrams: Double
    public let summary: String

    public init(id: UUID = UUID(), timestamp: Date, carbsGrams: Double, summary: String) {
        self.id = id
        self.timestamp = timestamp
        self.carbsGrams = carbsGrams
        self.summary = summary
    }
}

public func meals(_ meals: [Meal], within window: HistoryWindow, of now: Date) -> [Meal] {
    let cutoff = now.addingTimeInterval(-Double(window.hours) * 3600)
    return meals.filter { $0.timestamp >= cutoff && $0.timestamp <= now }
}

/// Every meal within `tolerance` of a hovered date, oldest first.
public func meals(near date: Date, in meals: [Meal], tolerance: TimeInterval) -> [Meal] {
    meals
        .filter { abs($0.timestamp.timeIntervalSince(date)) <= tolerance }
        .sorted { $0.timestamp < $1.timestamp }
}

public func carbTotal(_ meals: [Meal]) -> Double {
    meals.reduce(0) { $0 + $1.carbsGrams }
}

public func formatGrams(_ grams: Double) -> String {
    String(format: "%.0f", grams.rounded())
}

public let anthropicKeychainServicePrefix = "no.ignite.sugarbar.anthropic"

public func anthropicAPIKey(fromEnvironment environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
    environment["SUGARBAR_ANTHROPIC_API_KEY"]
}
