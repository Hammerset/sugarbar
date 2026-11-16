import Foundation

/// Meals that arrived through Sync and still need their Apple Health samples brought in line.
/// Written before the Meal store changes, so an app kill in between cannot skip a Meal.
public final class MealMirrorQueue: @unchecked Sendable {
    private static let key = "health.pendingMealMirror"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var pending: [UUID] {
        (defaults.stringArray(forKey: Self.key) ?? []).compactMap(UUID.init(uuidString:))
    }

    public func add(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let merged = pending + ids.filter { !pending.contains($0) }
        defaults.set(merged.map(\.uuidString), forKey: Self.key)
    }

    public func remove(_ id: UUID) {
        defaults.set(pending.filter { $0 != id }.map(\.uuidString), forKey: Self.key)
    }
}
