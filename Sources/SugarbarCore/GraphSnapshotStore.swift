import Foundation

public protocol GraphSnapshotStore: Sendable {
    func load() -> GraphSnapshot?
    func save(_ snapshot: GraphSnapshot)
}

/// Shares the latest fetch with a widget process over the App Group suite.
public final class UserDefaultsGraphSnapshotStore: GraphSnapshotStore, @unchecked Sendable {
    private static let key = "shared.glucose.snapshot"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .sugarbarShared) {
        self.defaults = defaults
    }

    public func load() -> GraphSnapshot? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(GraphSnapshot.self, from: data)
    }

    public func save(_ snapshot: GraphSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

public final class InMemoryGraphSnapshotStore: GraphSnapshotStore, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: GraphSnapshot?

    public init() {}

    public func load() -> GraphSnapshot? {
        lock.withLock { snapshot }
    }

    public func save(_ snapshot: GraphSnapshot) {
        lock.withLock { self.snapshot = snapshot }
    }
}
