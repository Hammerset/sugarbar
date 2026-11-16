import Foundation
import Testing

@testable import SugarbarCore

struct SharedDefaultsSafetyTests {
    private func freshDefaults() -> UserDefaults {
        let suite = "sugarbar.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func migrationCopiesGroupDataOnceWithoutOverwritingLocalKeys() {
        let local = freshDefaults()
        local.set(9.0, forKey: "thresholds.high")

        let copied = SharedDefaultsMigration.run(
            from: ["thresholds.high": 11.0, "therapy.carbRatio": 12.0],
            into: local
        )
        SharedDefaultsMigration.run(from: ["therapy.carbRatio": 99.0], into: local)

        #expect(copied == 1)
        #expect(local.double(forKey: "thresholds.high") == 9.0)
        #expect(local.double(forKey: "therapy.carbRatio") == 12.0)
    }

    @Test func emptyGroupDomainLeavesMigrationPendingForWhenItBecomesReadable() {
        let local = freshDefaults()
        SharedDefaultsMigration.run(from: [:], into: local)
        SharedDefaultsMigration.run(from: ["therapy.carbRatio": 12.0], into: local)
        #expect(local.double(forKey: "therapy.carbRatio") == 12.0)
    }

    @Test func emptyDefaultsLookWipedOnlyWhenHistoryHasData() {
        let defaults = freshDefaults()
        #expect(sharedDefaultsLookWiped(defaults, historyHasData: true))
        #expect(!sharedDefaultsLookWiped(defaults, historyHasData: false))
        defaults.set(Data(), forKey: "shared.meals")
        #expect(!sharedDefaultsLookWiped(defaults, historyHasData: true))
    }
}
