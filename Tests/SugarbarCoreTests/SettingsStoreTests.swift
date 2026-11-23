import Foundation
import Testing

@testable import SugarbarCore

@Suite struct SettingsTests {
    @Test func defaultsAreSensible() {
        let settings = Settings.default
        #expect(settings.thresholds == .standard)
        #expect(settings.pollCadence == 60)
        #expect(settings.selectedPatientId == nil)
        #expect(settings.disclaimerAcknowledged == false)
    }
}

@Suite struct UserDefaultsSettingsStoreTests {
    private func freshStore() -> UserDefaultsSettingsStore {
        let suite = "sugarbar.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return UserDefaultsSettingsStore(defaults: defaults)
    }

    @Test func returnsDefaultsWhenEmpty() {
        #expect(freshStore().load() == .default)
    }

    @Test func roundTripsSettings() {
        let store = freshStore()
        let settings = Settings(
            thresholds: Thresholds(urgentLow: 3.5, low: 4.2, high: 9.0, urgentHigh: 14.0),
            pollCadence: 90,
            selectedPatientId: "p-42",
            disclaimerAcknowledged: true
        )
        store.save(settings)
        #expect(store.load() == settings)
    }

    @Test func fallsBackToStandardWhenStoredThresholdsInvalid() {
        let store = freshStore()
        store.save(Settings(
            thresholds: Thresholds(urgentLow: 10, low: 3, high: 4, urgentHigh: 5),
            pollCadence: 60,
            selectedPatientId: nil,
            disclaimerAcknowledged: false
        ))
        #expect(store.load().thresholds == .standard)
    }

    @Test func clampsCadenceIntoRange() {
        let store = freshStore()
        store.save(Settings(thresholds: .standard, pollCadence: 1, selectedPatientId: nil, disclaimerAcknowledged: false))
        #expect(store.load().pollCadence == Settings.cadenceRange.lowerBound)

        store.save(Settings(thresholds: .standard, pollCadence: 9000, selectedPatientId: nil, disclaimerAcknowledged: false))
        #expect(store.load().pollCadence == Settings.cadenceRange.upperBound)
    }

    @Test func clearsSelectedPatientWhenNil() {
        let store = freshStore()
        store.save(Settings(thresholds: .standard, pollCadence: 60, selectedPatientId: "p-1", disclaimerAcknowledged: false))
        store.save(Settings(thresholds: .standard, pollCadence: 60, selectedPatientId: nil, disclaimerAcknowledged: false))
        #expect(store.load().selectedPatientId == nil)
    }
}

@Suite struct TherapySettingsMigrationTests {
    @Test func settingsFromBeforePerClassAbsorptionKeepTheirTimings() throws {
        let old = #"{"insulinSensitivity":3,"carbRatio":12,"insulinDuration":18000,"insulinPeak":4500,"carbAbsorptionTime":7200}"#
        let therapy = try JSONDecoder().decode(TherapySettings.self, from: Data(old.utf8))
        #expect(therapy.fastCarbAbsorptionTime == 3600)
        #expect(therapy.slowCarbAbsorptionTime == 3 * 3600)
        #expect(therapy.trendBlendDuration == 30 * 60)
        #expect(therapy.carbFactorRange == 0.25...2.0)
        #expect(therapy.isValid)
    }
}
