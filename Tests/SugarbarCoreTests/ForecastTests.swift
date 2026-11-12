import Foundation
import Testing

@testable import SugarbarCore

@Suite struct ExponentialInsulinModelTests {
    private let model = ExponentialInsulinModel(peak: 75 * 60, duration: 6 * 3600)

    @Test func remainingFractionGoesFromOneToZeroOverTheDuration() {
        #expect(model.remainingFraction(after: -60) == 1)
        #expect(abs(model.remainingFraction(after: 0) - 1) < 1e-12)
        #expect(abs(model.remainingFraction(after: 6 * 3600 - 1)) < 1e-6)
        #expect(model.remainingFraction(after: 6 * 3600) == 0)
        let samples = stride(from: 0.0, through: 6 * 3600, by: 60).map(model.remainingFraction(after:))
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $0 >= $1 })
    }

    @Test func activityIsTheRateTheRemainingFractionFalls() {
        for t in stride(from: 600.0, to: 6 * 3600, by: 1800) {
            let derivative = (model.remainingFraction(after: t - 1) - model.remainingFraction(after: t + 1)) / 2
            #expect(abs(derivative - model.activity(after: t)) < 1e-9)
        }
    }

    @Test func activityIntegratesToOneAndPeaksAtThePeak() {
        let step = 10.0
        let total = stride(from: step / 2, to: 6 * 3600, by: step).reduce(0) { $0 + model.activity(after: $1) * step }
        #expect(abs(total - 1) < 1e-6)
        let busiest = stride(from: 0.0, through: 6 * 3600, by: 60).max { model.activity(after: $0) < model.activity(after: $1) }
        #expect(busiest == TimeInterval(75 * 60))
    }
}

@Suite struct ForecastTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let therapy = TherapySettings(insulinSensitivity: 2.5, carbRatio: 10)

    private func flat(_ value: Double) -> [Reading] {
        stride(from: 15, through: 0, by: -1).map {
            Reading(value: value, timestamp: now.addingTimeInterval(-Double($0) * 60), trend: .stable)
        }
    }

    private func single(_ value: Double) -> [Reading] {
        [Reading(value: value, timestamp: now, trend: .stable)]
    }

    private func bolus(_ units: Double, minutesAgo: Double) -> InsulinDose {
        InsulinDose(kind: .bolus, units: units, timestamp: now.addingTimeInterval(-minutesAgo * 60), insulinName: nil, deviceName: nil)
    }

    private func meal(_ grams: Double, minutesAgo: Double) -> Meal {
        Meal(timestamp: now.addingTimeInterval(-minutesAgo * 60), carbsGrams: grams, summary: "")
    }

    private func run(
        _ readings: [Reading],
        doses: [InsulinDose] = [],
        meals: [Meal] = [],
        therapy: TherapySettings? = nil,
        sensorActivation: Date? = nil
    ) -> Forecast? {
        forecast(
            readings: readings, doses: doses, meals: meals, therapy: therapy ?? self.therapy,
            thresholds: .standard, sensorActivation: sensorActivation, now: now
        )
    }

    @Test func flatInputGivesFlatForecast() throws {
        let result = try #require(run(flat(6.0)))
        #expect(result.points.count == 37)
        #expect(result.points.first?.date == now)
        #expect(result.points.last?.date == now.addingTimeInterval(3 * 3600))
        #expect(result.points.allSatisfy { abs($0.value - 6.0) < 1e-9 })
        #expect(result.lowCrossing == nil)
        #expect(result.highCrossing == nil)
        #expect(result.insulinOnBoard == 0)
        #expect(result.carbsOnBoard == 0)
    }

    @Test func aDoseLowersGlucoseByUnitsTimesSensitivityOverItsDuration() throws {
        let result = try #require(run(single(20), doses: [bolus(4, minutesAgo: 0)]))
        #expect(abs((20 - result.eventual) - 4 * 2.5) < 1e-9)
    }

    @Test func runsUntilTheLastEffectHasFinished() throws {
        let dose = try #require(run(single(20), doses: [bolus(4, minutesAgo: 60)]))
        #expect(dose.points.last?.date == now.addingTimeInterval(5 * 3600))
        let meal = try #require(run(single(6), meals: [meal(20, minutesAgo: 0)], therapy: TherapySettings(insulinSensitivity: 2.5, carbRatio: 10, carbAbsorptionTime: 4 * 3600)))
        #expect(meal.points.last?.date == now.addingTimeInterval(4 * 3600))
        let finished = try #require(run(flat(6), doses: [bolus(4, minutesAgo: 5 * 60)]))
        #expect(finished.points.last?.date == now.addingTimeInterval(forecastDisplayHorizon))
    }

    @Test func mealRaisesGlucoseByGramsTimesSensitivityOverRatio() throws {
        let result = try #require(run(single(6), meals: [meal(40, minutesAgo: 0)]))
        #expect(abs(result.eventual - (6 + 40 * 2.5 / 10)) < 1e-9)
        let halfway = try #require(result.points.first { $0.date == now.addingTimeInterval(90 * 60) })
        #expect(abs(halfway.value - (6 + 20 * 2.5 / 10)) < 1e-9)
    }

    @Test func doseOlderThanTheDurationHasNoEffect() throws {
        let result = try #require(run(flat(7), doses: [bolus(10, minutesAgo: 6 * 60 + 1)]))
        #expect(result.points.allSatisfy { abs($0.value - 7) < 1e-9 })
        #expect(result.insulinOnBoard == 0)
    }

    @Test func basalIsIgnored() throws {
        let basal = InsulinDose(kind: .basal, units: 20, timestamp: now.addingTimeInterval(-3600), insulinName: nil, deviceName: nil)
        let result = try #require(run(flat(7), doses: [basal]))
        #expect(result.eventual == 7)
        #expect(result.insulinOnBoard == 0)
    }

    @Test func reportsInsulinAndCarbsOnBoardAtNow() throws {
        let result = try #require(run(single(8), doses: [bolus(4, minutesAgo: 120)], meals: [meal(60, minutesAgo: 60)]))
        let model = ExponentialInsulinModel(peak: 75 * 60, duration: 6 * 3600)
        #expect(abs(result.insulinOnBoard - 4 * model.remainingFraction(after: 7200)) < 1e-12)
        #expect(abs(result.carbsOnBoard - 40) < 1e-9)
    }

    @Test func momentumCarriesTheRecentSlopeAndFadesOverThirtyMinutes() throws {
        let rising = stride(from: 15, through: 0, by: -1).map {
            Reading(value: 8 - 0.1 * Double($0), timestamp: now.addingTimeInterval(-Double($0) * 60), trend: .rising)
        }
        let result = try #require(run(rising))
        #expect(abs(result.eventual - (8 + 0.1 * 15)) < 1e-9)
        let afterBlend = result.points.filter { $0.date >= now.addingTimeInterval(30 * 60) }
        #expect(afterBlend.allSatisfy { abs($0.value - result.eventual) < 1e-9 })
    }

    @Test func momentumIsSkippedWhenReadingsAreTooFewOrGapped() throws {
        let sparse = [
            Reading(value: 5, timestamp: now.addingTimeInterval(-15 * 60), trend: .rising),
            Reading(value: 8, timestamp: now, trend: .rising),
        ]
        #expect(try #require(run(sparse)).eventual == 8)

        let gapped = [
            Reading(value: 5, timestamp: now.addingTimeInterval(-15 * 60), trend: .rising),
            Reading(value: 5.1, timestamp: now.addingTimeInterval(-14 * 60), trend: .rising),
            Reading(value: 7.9, timestamp: now.addingTimeInterval(-60), trend: .rising),
            Reading(value: 8, timestamp: now, trend: .rising),
        ]
        #expect(try #require(run(gapped)).eventual == 8)
    }

    @Test func momentumSlopeIsCappedAgainstNoise() throws {
        let jump = stride(from: 6, through: 0, by: -1).map {
            Reading(value: $0 == 0 ? 15 : 5, timestamp: now.addingTimeInterval(-Double($0) * 60), trend: .stable)
        }
        let result = try #require(run(jump))
        #expect(result.eventual - 15 <= 0.25 * 15 + 1e-9)
    }

    @Test func findsTheFirstLowAndHighCrossings() throws {
        let falling = try #require(run(single(6), doses: [bolus(3, minutesAgo: 0)]))
        let low = try #require(falling.lowCrossing)
        let before = try #require(falling.points.last { $0.date < low })
        let at = try #require(falling.points.first { $0.date == low })
        #expect(before.value >= 3.9 && at.value < 3.9)
        #expect(falling.highCrossing == nil)

        let rising = try #require(run(single(8), meals: [meal(30, minutesAgo: 0)]))
        #expect(rising.highCrossing != nil)
        #expect(rising.lowCrossing == nil)
    }

    @Test func alreadyLowIsNotACrossing() throws {
        #expect(try #require(run(flat(3.5))).lowCrossing == nil)
    }

    @Test func noForecastWithoutCompleteValidTherapySettings() {
        #expect(run(flat(6), therapy: TherapySettings(insulinSensitivity: 2.5)) == nil)
        #expect(run(flat(6), therapy: TherapySettings(carbRatio: 10)) == nil)
        #expect(run(flat(6), therapy: TherapySettings(insulinSensitivity: 2.5, carbRatio: 10, insulinDuration: 4 * 3600, insulinPeak: 120 * 60)) == nil)
    }

    @Test func noForecastFromAStaleReadingOrDuringWarmUpOrAtTheSensorLimit() {
        let stale = [Reading(value: 6, timestamp: now.addingTimeInterval(-301), trend: .stable)]
        #expect(run(stale) == nil)
        #expect(run(flat(6), sensorActivation: now.addingTimeInterval(-30 * 60)) == nil)
        #expect(run(single(mmolPerL(fromMgPerDl: 40))) == nil)
        #expect(run([]) == nil)
    }
}

@Suite struct TherapySettingsTests {
    private func freshDefaults() -> UserDefaults {
        let suite = "sugarbar.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func defaultsAreIncompleteButValid() {
        #expect(TherapySettings.default.isComplete == false)
        #expect(TherapySettings.default.isValid)
        #expect(TherapySettings.default.insulinPeak == 75 * 60)
        #expect(TherapySettings.default.insulinDuration == 6 * 3600)
        #expect(TherapySettings.default.carbAbsorptionTime == 3 * 3600)
    }

    @Test func rejectsOutOfRangeValues() {
        #expect(TherapySettings(insulinSensitivity: 0).isValid == false)
        #expect(TherapySettings(carbRatio: 500).isValid == false)
        #expect(TherapySettings(insulinDuration: 3600).isValid == false)
        #expect(TherapySettings(carbAbsorptionTime: 10 * 3600).isValid == false)
    }

    @Test func settingsWithoutStoredTherapyLoadDefaults() {
        let defaults = freshDefaults()
        defaults.set(3.5, forKey: "thresholds.urgentLow")
        #expect(UserDefaultsSettingsStore(defaults: defaults).load().therapy == .default)
    }

    @Test func roundTripsAndClearsTherapySettings() {
        let store = UserDefaultsSettingsStore(defaults: freshDefaults())
        var settings = Settings.default
        settings.therapy = TherapySettings(insulinSensitivity: 2.5, carbRatio: 12, insulinDuration: 5 * 3600, insulinPeak: 55 * 60, carbAbsorptionTime: 2 * 3600)
        store.save(settings)
        #expect(store.load() == settings)

        settings.therapy.insulinSensitivity = nil
        store.save(settings)
        #expect(store.load().therapy.insulinSensitivity == nil)
    }

    @Test func dropsTamperedStoredValues() {
        let defaults = freshDefaults()
        defaults.set(-1.0, forKey: "therapy.insulinSensitivity")
        defaults.set(10.0, forKey: "therapy.carbRatio")
        defaults.set(60.0, forKey: "therapy.insulinPeak")
        let therapy = UserDefaultsSettingsStore(defaults: defaults).load().therapy
        #expect(therapy.insulinSensitivity == nil)
        #expect(therapy.carbRatio == 10)
        #expect(therapy.insulinPeak == 75 * 60)
    }
}
