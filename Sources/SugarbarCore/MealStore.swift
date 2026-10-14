import Foundation

public protocol MealStore: Sendable {
    func load() -> [Meal]
    func save(_ meals: [Meal])
}

/// Meals live in the App Group suite so the Mac panel and the widget can read what the phone logged.
public final class UserDefaultsMealStore: MealStore, @unchecked Sendable {
    private static let key = "shared.meals"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .sugarbarShared) {
        self.defaults = defaults
    }

    public func load() -> [Meal] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        return (try? JSONDecoder().decode([Meal].self, from: data)) ?? []
    }

    public func save(_ meals: [Meal]) {
        guard let data = try? JSONEncoder().encode(meals) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

public final class InMemoryMealStore: MealStore, @unchecked Sendable {
    private let lock = NSLock()
    private var meals: [Meal] = []

    public init() {}

    public func load() -> [Meal] {
        lock.withLock { meals }
    }

    public func save(_ meals: [Meal]) {
        lock.withLock { self.meals = meals }
    }
}
