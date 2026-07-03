import Foundation
import Testing

@testable import SugarbarCore

private let sampleSnapshot = GraphSnapshot(
    latest: Reading(value: 5.5, timestamp: Date(timeIntervalSince1970: 1_719_400_500), trend: .rising),
    history: [
        Reading(value: 5.0, timestamp: Date(timeIntervalSince1970: 1_719_400_000), trend: .notDetermined),
    ],
    sensorActivation: Date(timeIntervalSince1970: 1_719_000_000)
)

@Suite struct InMemoryGraphSnapshotStoreTests {
    @Test func roundTripsSnapshot() {
        let store = InMemoryGraphSnapshotStore()
        #expect(store.load() == nil)

        store.save(sampleSnapshot)
        #expect(store.load() == sampleSnapshot)
    }
}

@Suite struct UserDefaultsGraphSnapshotStoreTests {
    private func freshStore() -> UserDefaultsGraphSnapshotStore {
        let suite = "sugarbar.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return UserDefaultsGraphSnapshotStore(defaults: defaults)
    }

    @Test func returnsNilWhenEmpty() {
        #expect(freshStore().load() == nil)
    }

    @Test func roundTripsSnapshot() {
        let store = freshStore()
        store.save(sampleSnapshot)
        #expect(store.load() == sampleSnapshot)
    }

    @Test func overwritesPreviousSnapshot() {
        let store = freshStore()
        store.save(sampleSnapshot)
        let updated = GraphSnapshot(latest: nil, history: [], sensorActivation: nil)
        store.save(updated)
        #expect(store.load() == updated)
    }
}

extension AppGroupDefaultsTests {
    @Test func snapshotStoreDefaultTargetsAppGroupSuite() {
        UserDefaults.sugarbarShared.removePersistentDomain(forName: sugarbarAppGroupIdentifier)
        defer { UserDefaults.sugarbarShared.removePersistentDomain(forName: sugarbarAppGroupIdentifier) }

        UserDefaultsGraphSnapshotStore().save(sampleSnapshot)

        #expect(UserDefaultsGraphSnapshotStore().load() == sampleSnapshot)
        #expect(UserDefaults.sugarbarShared.data(forKey: "shared.glucose.snapshot") != nil)
    }
}
