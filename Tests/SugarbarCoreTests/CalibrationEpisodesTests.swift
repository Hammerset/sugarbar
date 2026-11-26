import Foundation
import Testing

@testable import SugarbarCore

/// Glucose every 5 minutes from a flat 7 plus the effect of Boluses and Meals under `truth`, plus `extra`.
struct SyntheticHistory {
    var start = Date(timeIntervalSince1970: 1_795_000_000)
    var hours = 12.0
    var truth = TherapySettings(insulinSensitivity: 3, carbRatio: 10, insulinDuration: 5 * 3600)
    var boluses: [(hour: Double, units: Double)] = []
    var meals: [(hour: Double, grams: Double)] = []
    /// Unlogged rises, linear over an hour from `hour`.
    var rises: [(hour: Double, amount: Double)] = []
    var extra: (Double) -> Double = { _ in 0 }

    func date(_ hour: Double) -> Date { start.addingTimeInterval(hour * 3600) }
    var now: Date { date(hours) }

    var doses: [InsulinDose] {
        boluses.map { InsulinDose(kind: .bolus, units: $0.units, timestamp: date($0.hour), insulinName: nil, deviceName: nil) }
    }

    var loggedMeals: [Meal] {
        meals.map { Meal(timestamp: date($0.hour), carbsGrams: $0.grams, summary: "") }
    }

    var readings: [Reading] {
        let model = ExponentialInsulinModel(peak: truth.insulinPeak, duration: truth.insulinDuration)
        let sensitivity = truth.insulinSensitivity!
        return stride(from: 0.0, through: hours * 60, by: 5).map { minute in
            let t = date(minute / 60)
            let hour = minute / 60
            var value = 7 + extra(hour) + rises.reduce(0) { $0 + $1.amount * min(max(hour - $1.hour, 0), 1) }
            for dose in doses where dose.timestamp <= t {
                value -= dose.units * sensitivity * (1 - model.remainingFraction(after: t.timeIntervalSince(dose.timestamp)))
            }
            for meal in loggedMeals where meal.timestamp <= t {
                value += meal.carbsAbsorbed(at: t, therapy: truth) * sensitivity / truth.carbRatio!
            }
            return Reading(value: value, timestamp: t, trend: .notDetermined)
        }
    }

    var data: CalibrationData {
        CalibrationData(readings: readings, doses: doses, meals: loggedMeals, thresholds: .standard, now: now)
    }

    func labels(believing therapy: TherapySettings? = nil, excludedDays: [ExcludedDay] = [], calendar: Calendar = .utc) -> CalibrationTimeline {
        labelCalibrationEpisodes(
            readings: readings, doses: doses, meals: loggedMeals, therapy: therapy ?? truth,
            excludedDays: excludedDays, calendar: calendar
        )
    }
}

extension Calendar {
    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
}

@Suite struct CalibrationEpisodesTests {
    private func label(_ timeline: CalibrationTimeline, _ history: SyntheticHistory, at hour: Double) -> CalibrationLabel? {
        timeline.label(at: history.date(hour))
    }

    @Test func aBolusWithNoMealNearItIsACorrectionForFiveHoursThenQuiet() {
        let history = SyntheticHistory(boluses: [(2, 1.5)])
        let timeline = history.labels()
        #expect(label(timeline, history, at: 1) == .episode(.quiet))
        #expect(label(timeline, history, at: 2) == .episode(.correction))
        #expect(label(timeline, history, at: 6.9) == .episode(.correction))
        #expect(label(timeline, history, at: 7.1) == .episode(.quiet))
        #expect(timeline.episodes.map(\.label) == [.episode(.quiet), .episode(.correction), .episode(.quiet)])
    }

    @Test func aBolusWithAMealSoonAfterOrWithinThreeHoursBeforeIsAMeal() {
        let preBolused = SyntheticHistory(boluses: [(2, 4)], meals: [(2.25, 40)])
        let timeline = preBolused.labels()
        #expect(label(timeline, preBolused, at: 2.1) == .episode(.meal))
        #expect(label(timeline, preBolused, at: 7) == .episode(.meal))
        #expect(label(timeline, preBolused, at: 7.4) == .episode(.quiet))

        let lateBolus = SyntheticHistory(hours: 10, boluses: [(4, 2)], meals: [(1.5, 20)])
        #expect(label(lateBolus.labels(), lateBolus, at: 8.5) == .episode(.meal))
    }

    @Test func aMealLongAfterACorrectionEndsItThere() {
        let history = SyntheticHistory(boluses: [(1, 1.5)], meals: [(4, 30)])
        let timeline = history.labels()
        #expect(label(timeline, history, at: 3.9) == .episode(.correction))
        #expect(label(timeline, history, at: 4.1) == .episode(.meal))
    }

    @Test func nothingForFiveHoursIsQuiet() {
        let history = SyntheticHistory(hours: 6)
        #expect(Set(history.labels().labels) == [.episode(.quiet)])
    }

    @Test func aRiseNoInsulinOrMealExplainsIsExcludedWithTwoHoursOfTail() {
        let history = SyntheticHistory(extra: { hour in hour < 3 ? 0 : 3 * min(hour - 3, 1) })
        let timeline = history.labels()
        #expect(label(timeline, history, at: 2.5) == .episode(.quiet))
        #expect(label(timeline, history, at: 3.5) == .excluded(.unloggedCarbs))
        #expect(label(timeline, history, at: 5.9) == .excluded(.unloggedCarbs))
        #expect(label(timeline, history, at: 6.5) == .episode(.quiet))
    }

    @Test func aRiseDespiteInsulinOnlyAFittingModelCannotExplainStillNeedsARealRise() {
        let tooStrong = TherapySettings(insulinSensitivity: 4.5, carbRatio: 10, insulinDuration: 5 * 3600)
        let history = SyntheticHistory(boluses: [(1, 1)], extra: { hour in hour < 2 ? 0 : 0.6 * min(hour - 2, 1) })
        #expect(!history.labels(believing: tooStrong).labels.contains(.excluded(.unloggedCarbs)))
    }

    @Test func aRiseFromBelowLowIsATreatedLow() {
        let history = SyntheticHistory(extra: { hour in hour < 2 ? -3.8 : -3.8 + 0.8 * min(hour - 2, 0.5) / 0.5 })
        #expect(label(history.labels(), history, at: 2.5) == .excluded(.unloggedCarbs))
    }

    @Test func aRiseTheNextBolusCorrectsExcludesOnlyTheRise() {
        let history = SyntheticHistory(boluses: [(3.5, 1)], extra: { hour in hour < 3 ? 0 : 2 * min(hour - 3, 0.5) / 0.5 })
        let timeline = history.labels()
        #expect(label(timeline, history, at: 3.4) == .excluded(.unloggedCarbs))
        #expect(label(timeline, history, at: 4) == .episode(.correction))
    }

    @Test func aBolusThatWouldTakeGlucoseBelowTwoWithoutFoodWasForUnloggedCarbs() {
        let mealSized = SyntheticHistory(boluses: [(2, 2.5)], rises: [(2.25, 7.5)])
        let timeline = mealSized.labels()
        #expect(label(timeline, mealSized, at: 2) == .excluded(.unloggedCarbs))
        #expect(label(timeline, mealSized, at: 6.9) == .excluded(.unloggedCarbs))
        #expect(label(timeline, mealSized, at: 7.5) == .episode(.quiet))

        let correction = SyntheticHistory(boluses: [(2, 1.5)])
        #expect(label(correction.labels(), correction, at: 2) == .episode(.correction))
    }

    @Test func aMarkedDayIsExcludedWhole() {
        let history = SyntheticHistory(start: Date(timeIntervalSince1970: 1_795_392_000), hours: 30, boluses: [(2, 1)])
        let day = ExcludedDay(date: history.date(0), reason: .sick, calendar: .utc)
        let timeline = history.labels(excludedDays: [day])
        #expect(day.day == "2026-11-23")
        #expect(label(timeline, history, at: 2) == .excluded(.excludedDay))
        #expect(label(timeline, history, at: 23.9) == .excluded(.excludedDay))
        #expect(label(timeline, history, at: 24.1) == .episode(.quiet))
    }

    @Test func learningSavedBeforeExcludedDaysStartsWithTheSickDays() throws {
        let old = Data(#"{"changes":[],"dismissed":[]}"#.utf8)
        let learning = try JSONDecoder().decode(TherapyLearning.self, from: old)
        #expect(learning.excludedDays.map(\.day) == ["2026-11-23", "2026-11-24", "2026-11-25"])

        var edited = learning
        edited.setExcluded("2026-11-24", reason: nil)
        edited.setExcluded("2026-11-01", reason: .alcohol)
        let roundTripped = try JSONDecoder().decode(TherapyLearning.self, from: JSONEncoder().encode(edited))
        #expect(roundTripped.excludedDays == [
            ExcludedDay(day: "2026-11-01", reason: .alcohol),
            ExcludedDay(day: "2026-11-23", reason: .sick),
            ExcludedDay(day: "2026-11-25", reason: .sick),
        ])
    }
}
