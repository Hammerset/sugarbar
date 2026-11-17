import Foundation
import Testing

@testable import SugarbarCore

private let t1515 = Date(timeIntervalSince1970: 1_794_488_100)
private let t1640 = t1515.addingTimeInterval(85 * 60)
private let t1715 = t1515.addingTimeInterval(120 * 60)
private let therapy = TherapySettings(insulinSensitivity: 3.0, carbRatio: 10, insulinDuration: 6 * 3600, insulinPeak: 75 * 60)

private func bolus(_ units: Double, at date: Date) -> InsulinDose {
    InsulinDose(kind: .bolus, units: units, timestamp: date, insulinName: "Fiasp", deviceName: "pen")
}

private func warning(
    units: Double = 1,
    kind: InsulinKind = .bolus,
    doses: [InsulinDose],
    glucose: Double? = 11.0,
    therapy: TherapySettings = therapy,
    dosing: DosingSettings = .default
) -> StackingWarning? {
    stackingWarning(
        units: units,
        kind: kind,
        timestamp: t1715,
        doses: doses,
        latest: glucose.map { Reading(value: $0, timestamp: t1715.addingTimeInterval(-60), trend: .rising) },
        therapy: therapy,
        dosing: dosing,
        thresholds: .standard,
        now: t1715
    )
}

@Suite struct BolusStackingTests {
    @Test func ownersCorrectionDuringPostMealRiseWouldEndLow() throws {
        let doses = [bolus(1, at: t1515), bolus(3, at: t1640), bolus(2.5, at: t1640)]
        let result = try #require(warning(doses: doses))
        let model = ExponentialInsulinModel(peak: 75 * 60, duration: 6 * 3600)
        let expected = 1 * model.remainingFraction(after: 120 * 60) + 5.5 * model.remainingFraction(after: 35 * 60)
        #expect(abs(result.insulinOnBoard - expected) < 1e-9)
        #expect(result.insulinOnBoard > 5)
        #expect(result.insulinOnBoardAboveLimit && result.previousBolusIsRecent)
        #expect(result.previousBolusTime == t1640)
        #expect(result.previousBolusUnits == 5.5)
        #expect(abs(try #require(result.remainingEffect) - expected * 3) < 1e-9)
        #expect(abs(try #require(result.effectWithDose) - (expected + 1) * 3) < 1e-9)
        #expect(abs(try #require(result.glucoseAfterDose) - (11 - (expected + 1) * 3)) < 1e-9)
        #expect(result.endsBelowLow)
        #expect(result.remainingDuration == 6 * 3600 - 35 * 60)
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
        let result = try #require(warning(doses: [bolus(3, at: t1640)], therapy: noSensitivity))
        #expect(result.insulinOnBoard > 2)
        #expect(result.remainingEffect == nil && result.effectWithDose == nil && result.glucoseAfterDose == nil)
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
