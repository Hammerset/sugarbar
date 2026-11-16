import Foundation

/// Keys whose presence shows Settings or Meals were saved at least once.
let sharedDataKeys = [
    "shared.meals",
    "disclaimer.acknowledged",
    "thresholds.urgentLow",
    "therapy.insulinSensitivity",
    "therapy.carbRatio",
    "therapy.learning",
]

/// Settings and Meals missing while History has data means the store was wiped or is unreadable,
/// not that this is a first launch.
public func sharedDefaultsLookWiped(_ defaults: UserDefaults, historyHasData: Bool) -> Bool {
    historyHasData && sharedDataKeys.allSatisfy { defaults.object(forKey: $0) == nil }
}

public enum SharedDefaultsMigration {
    static let doneKey = "storage.migratedFromAppGroup"

    /// Copies the App Group domain once. Local keys win, so readable-but-stale group data can never
    /// replace Settings or Meals saved here.
    @discardableResult
    public static func run(from source: [String: Any]?, into destination: UserDefaults) -> Int {
        guard !destination.bool(forKey: doneKey), let source, !source.isEmpty else { return 0 }
        var copied = 0
        for (key, value) in source where destination.object(forKey: key) == nil {
            destination.set(value, forKey: key)
            copied += 1
        }
        destination.set(true, forKey: doneKey)
        return copied
    }
}

/// Holds back Settings and Meal writes until the user has seen that storage came back empty.
public final class StoreWriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open: Bool

    public init(open: Bool = true) {
        self.open = open
    }

    public var isOpen: Bool { lock.withLock { open } }

    public func unlock() {
        lock.withLock { open = true }
    }
}

public final class GatedSettingsStore: SettingsStore, @unchecked Sendable {
    private let base: SettingsStore
    private let gate: StoreWriteGate

    public init(_ base: SettingsStore, gate: StoreWriteGate) {
        self.base = base
        self.gate = gate
    }

    public func load() -> Settings { base.load() }

    public func save(_ settings: Settings) {
        guard gate.isOpen else { return }
        base.save(settings)
    }
}

public final class GatedMealStore: MealStore, @unchecked Sendable {
    private let base: MealStore
    private let gate: StoreWriteGate

    public init(_ base: MealStore, gate: StoreWriteGate) {
        self.base = base
        self.gate = gate
    }

    public func load() -> [Meal] { base.load() }

    public func save(_ meals: [Meal]) {
        guard gate.isOpen else { return }
        base.save(meals)
    }
}
