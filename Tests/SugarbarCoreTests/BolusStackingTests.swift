import Foundation
import Testing

@testable import SugarbarCore

private let t1515 = Date(timeIntervalSince1970: 1_794_488_100)
private let t1640 = t1515.addingTimeInterval(85 * 60)
private let t1715 = t1515.addingTimeInterval(120 * 60)
private let t1650 = t1515.addingTimeInterval(95 * 60)
private let therapy = TherapySettings(insulinSensitivity: 3.0, carbRatio: 12, insulinDuration: 6 * 3600, insulinPeak: 75 * 60)
private let dinner = Meal(timestamp: t1650, carbsGrams: 80, summary: "Dinner")

private func bolus(_ units: Double, at date: Date) -> InsulinDose {
    InsulinDose(kind: .bolus, units: units, timestamp: date, insulinName: "Fiasp", deviceName: "pen")
}

private func warning(
    units: Double = 1,
    kind: InsulinKind = .bolus,
    doses: [InsulinDose],
    meals: [Meal] = [],
    glucose: Double? = 11.0,
    therapy: TherapySettings = therapy,
    dosing: DosingSettings = .default
) -> StackingWarning? {
    stackingWarning(
        units: units,
        kind: kind,
        timestamp: t1715,
        doses: doses,
        meals: meals,
        latest: glucose.map { Reading(value: $0, timestamp: t1715.addingTimeInterval(-60), trend: .rising) },
        therapy: therapy,
        dosing: dosing,
        thresholds: .standard,
        now: t1715
    )
}

@Suite struct BolusStackingTests {
    @Test func ownersCorrectionDuringPostMealRiseCountsInsulinAndCarbs() throws {
        let doses = [bolus(1, at: t1515), bolus(3, at: t1640), bolus(2.5, at: t1640)]
        let result = try #require(warning(doses: doses, meals: [dinner]))
        let model = ExponentialInsulinModel(peak: 75 * 60, duration: 6 * 3600)
        let onBoard = 1 * model.remainingFraction(after: 120 * 60) + 5.5 * model.remainingFraction(after: 35 * 60)
        let carbsLeft = 80 * (1 - 25.0 / 180)
        #expect(abs(result.insulinOnBoard - onBoard) < 1e-9)
        #expect(result.insulinOnBoardAboveLimit && result.previousBolusIsRecent)
        #expect(result.previousBolusTime == t1640)
        #expect(result.previousBolusUnits == 5.5)
        #expect(abs(try #require(result.remainingEffect) - onBoard * 3) < 1e-9)
        #expect(abs(try #require(result.effectWithDose) - (onBoard + 1) * 3) < 1e-9)
        #expect(abs(result.carbsOnBoard - carbsLeft) < 1e-9)
        #expect(abs(try #require(result.remainingCarbEffect) - carbsLeft * 3 / 12) < 1e-9)
        #expect(abs(try #require(result.glucoseAfterDose) - (11 - (onBoard + 1) * 3 + carbsLeft * 3 / 12)) < 1e-9)
        #expect(!result.endsBelowLow)
        #expect(try #require(warning(doses: doses, meals: [dinner], glucose: 5.5)).endsBelowLow)
        #expect(result.remainingDuration == 6 * 3600 - 35 * 60)
    }

    @Test func withoutCarbRatioProjectsInsulinAlone() throws {
        let doses = [bolus(1, at: t1515), bolus(3, at: t1640), bolus(2.5, at: t1640)]
        let noRatio = TherapySettings(insulinSensitivity: 3.0, carbRatio: nil)
        let result = try #require(warning(doses: doses, meals: [dinner], therapy: noRatio))
        #expect(result.carbsOnBoard > 60 && result.remainingCarbEffect == nil)
        #expect(result.endsBelowLow)
    }

    @Test func plannedMealsAndLaterMealsAreNotCounted() throws {
        let planned = Meal(timestamp: t1650, carbsGrams: 80, summary: "", state: .planned)
        let later = Meal(timestamp: t1715.addingTimeInterval(60), carbsGrams: 80, summary: "")
        let result = try #require(warning(doses: [bolus(3, at: t1640)], meals: [planned, later]))
        #expect(result.carbsOnBoard == 0)
    }

    @Test func noWarningBelowBothThresholds() {
        #expect(warning(doses: [bolus(1, at: t1515)]) == nil)
    }

    @Test func eachThresholdWarnsOnItsOwn() throws {
        let recentSmall = try #require(warning(doses: [bolus(0.5, at: t1715.addingTimeInterval(-90 * 60))]))
        #expect(recentSmall.previousBolusIsRecent && !recentSmall.insulinOnBoardAboveLimit)

        let oldLarge = try #require(warning(doses: [bolus(8, at: t1715.addingTimeInterval(-150 * 60))]))
        #expect(oldLarge.insulinOnBoardAboveLimit && !oldLarge.previousBolusIsRecent)

        let looser = DosingSettings(stackingInsulinOnBoard: 6, stackingInterval: 3600)
        #expect(warning(doses: [bolus(8, at: t1715.addingTimeInterval(-150 * 60))], dosing: looser) == nil)
    }

    @Test func endsAboveLowWhenGlucoseIsHighEnough() throws {
        let result = try #require(warning(doses: [bolus(3, at: t1640)], glucose: 20))
        #expect(!result.endsBelowLow)
    }

    @Test func withoutSensitivityShowsInsulinOnBoardOnly() throws {
        let noSensitivity = TherapySettings(insulinSensitivity: nil, carbRatio: 10)
        let result = try #require(warning(doses: [bolus(3, at: t1640)], meals: [dinner], therapy: noSensitivity))
        #expect(result.insulinOnBoard > 2)
        #expect(result.remainingEffect == nil && result.effectWithDose == nil && result.glucoseAfterDose == nil)
        #expect(result.remainingCarbEffect == nil)
        #expect(!result.endsBelowLow)
    }

    @Test func basalNeitherWarnsNorCounts() {
        #expect(warning(kind: .basal, doses: [bolus(3, at: t1640)]) == nil)
        let basal = InsulinDose(kind: .basal, units: 20, timestamp: t1640, insulinName: nil, deviceName: nil)
        #expect(warning(doses: [basal]) == nil)
    }

    @Test func storedSettingsWithoutStackingKeysDecodeToDefaults() throws {
        let stored = try JSONDecoder().decode(DosingSettings.self, from: Data(#"{"targetGlucose": 5.5, "penStep": 0.5, "maxSingleDose": 10}"#.utf8))
        #expect(stored.stackingInsulinOnBoard == 2 && stored.stackingInterval == 2 * 3600)
    }
}
