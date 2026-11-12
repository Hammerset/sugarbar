import Foundation
import Testing

@testable import SugarbarCore

private let now = Date(timeIntervalSince1970: 1_794_488_820)

private func input(
    carbs: Double = 60,
    glucose: Double? = 9.0,
    readingAge: TimeInterval = 60,
    onBoard: Double? = 1.2,
    therapy: TherapySettings = TherapySettings(insulinSensitivity: 2.5, carbRatio: 10),
    dosing: DosingSettings = .default,
    sensorActivation: Date? = nil
) -> DoseSuggestionInput {
    DoseSuggestionInput(
        carbsGrams: carbs,
        therapy: therapy,
        dosing: dosing,
        thresholds: .standard,
        latest: glucose.map { Reading(value: $0, timestamp: now.addingTimeInterval(-readingAge), trend: .stable) },
        sensorActivation: sensorActivation,
        insulinOnBoard: onBoard,
        now: now
    )
}

@Suite struct SuggestedDoseTests {
    @Test func addsMealAndCorrectionThenDeductsInsulinOnBoardAndRoundsDown() throws {
        let dose = try #require(suggestDose(input()).dose)
        #expect(dose.mealUnits == 6)
        #expect(abs(dose.correctionUnits - 1.2) < 1e-9)
        #expect(abs(dose.insulinOnBoardDeduction - 1.2) < 1e-9)
        #expect(abs(dose.unroundedUnits - 6.0) < 1e-9)
        #expect(dose.units == 6)
        #expect(!dose.wasCapped)

        let halfSteps = try #require(suggestDose(input(onBoard: 0.3, dosing: DosingSettings(penStep: 0.5))).dose)
        #expect(abs(halfSteps.unroundedUnits - 6.9) < 1e-9)
        #expect(halfSteps.units == 6.5)
        #expect(try #require(suggestDose(input(onBoard: 0.3)).dose).units == 6)
    }

    @Test func belowTargetCorrectionIsNegativeAndShrinksTheMealPart() throws {
        let dose = try #require(suggestDose(input(glucose: 5.0, onBoard: 0)).dose)
        #expect(abs(dose.correctionUnits - (-0.4)) < 1e-9)
        #expect(abs(dose.unroundedUnits - 5.6) < 1e-9)
        #expect(dose.units == 5)
    }

    @Test func insulinOnBoardNeverMakesTheDoseNegative() throws {
        let dose = try #require(suggestDose(input(carbs: 10, glucose: 6.0, onBoard: 4)).dose)
        #expect(dose.insulinOnBoardDeduction == 1)
        #expect(dose.unroundedUnits == 0)
        #expect(dose.units == 0)

        let belowTarget = try #require(suggestDose(input(carbs: 0, glucose: 4.5, onBoard: 2)).dose)
        #expect(belowTarget.insulinOnBoardDeduction == 0)
        #expect(belowTarget.units == 0)
    }

    @Test func capsAtTheMaximumSingleDose() throws {
        let dose = try #require(suggestDose(input(carbs: 200, glucose: 15, onBoard: 0)).dose)
        #expect(dose.wasCapped)
        #expect(dose.unroundedUnits == 15)
        #expect(dose.units == 15)

        let lowCap = try #require(suggestDose(input(dosing: DosingSettings(maxSingleDose: 4.5))).dose)
        #expect(lowCap.wasCapped)
        #expect(lowCap.units == 4)
    }

    @Test func withholdsWithoutTherapySettingsOrAFreshReading() {
        #expect(suggestDose(input(therapy: TherapySettings(carbRatio: 10))) == .withheld([.noTherapySettings]))
        #expect(suggestDose(input(glucose: nil, therapy: .default)) == .withheld([.noTherapySettings, .noReading]))
        #expect(suggestDose(input(readingAge: 6 * 60)) == .withheld([.staleReading]))
        #expect(suggestDose(input(sensorActivation: now.addingTimeInterval(-10 * 60))) == .withheld([.sensorWarmingUp]))
        #expect(suggestDose(input(glucose: nil, sensorActivation: now.addingTimeInterval(-10 * 60))) == .withheld([.sensorWarmingUp]))
        #expect(suggestDose(input(glucose: 28)) == .withheld([.outsideSensorRange]))
        #expect(suggestDose(input(onBoard: nil)) == .withheld([.insulinOnBoardUnknown]))
    }

    @Test func lowGlucoseSaysTreatTheLowFirstWhateverElseIsMissing() {
        #expect(suggestDose(input(glucose: 3.6)) == .withheld([.glucoseLow]))
        #expect(suggestDose(input(glucose: 2.0, therapy: .default)) == .withheld([.glucoseLow]))
        #expect(DoseWithheldReason.glucoseLow.message.contains("Treat the low first"))
    }

    @Test func dosingSettingsDecodeSafelyFromPartialOrBadData() throws {
        let decoder = JSONDecoder()
        #expect(try decoder.decode(DosingSettings.self, from: Data("{}".utf8)) == .default)
        let odd = try decoder.decode(DosingSettings.self, from: Data(#"{"targetGlucose": 2, "penStep": 0.3, "maxSingleDose": 20}"#.utf8))
        #expect(odd == DosingSettings(targetGlucose: 6, penStep: 1, maxSingleDose: 20))

        let suite = "sugarbar.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let store = UserDefaultsSettingsStore(defaults: defaults)
        #expect(store.load().dosing == .default)
        var settings = store.load()
        settings.dosing = DosingSettings(targetGlucose: 5.5, penStep: 0.5, maxSingleDose: 10)
        store.save(settings)
        #expect(store.load().dosing == settings.dosing)
    }
}
