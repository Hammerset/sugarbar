import Foundation
import Testing

@testable import SugarbarCore

@Suite struct CalibrationBacktestTests {
    /// Two corrections a day, 12 hours apart, each of a rise the hour before, for `days` days.
    private func corrections(days: Int, truth: TherapySettings) -> SyntheticHistory {
        let boluses = (0..<days).flatMap { day in [(Double(day) * 24 + 2, 1.5), (Double(day) * 24 + 14, 1.0)] }
        return SyntheticHistory(
            hours: Double(days) * 24,
            truth: truth,
            boluses: boluses,
            rises: boluses.map { ($0.0 - 1, $0.1 * truth.insulinSensitivity!) }
        )
    }

    private let believed = TherapySettings(insulinSensitivity: 3, carbRatio: 10, insulinDuration: 5 * 3600, insulinPeak: 75 * 60)

    @Test func atTheAppsSpacingItReproducesTheAppsOwnReplay() throws {
        let truth = TherapySettings(insulinSensitivity: 2.4, carbRatio: 10, insulinDuration: 4 * 3600, insulinPeak: 55 * 60)
        var history = corrections(days: 16, truth: truth)
        history.meals = [(30, 40), (100, 60)]
        history.boluses += [(30, 4), (100, 6)]
        let options = ForecastLearningOptions.default
        let learning = learnForecastParameters(
            readings: history.readings, doses: history.doses, meals: history.loggedMeals, therapy: believed,
            thresholds: .standard, now: history.now, options: options, calendar: .utc
        )
        let app = try #require(learning.replayScorecard)
        let recent = backtestForecast(
            history.data, therapy: believed, excludedDays: [],
            interval: history.now.addingTimeInterval(-14 * 86400)...history.now.addingTimeInterval(-options.settleTime),
            spacing: options.sampleSpacing, calendar: .utc
        )
        #expect(recent.all == app.overall)
        #expect(recent.forecastCount == app.forecastCount)
    }

    @Test func tooStrongASensitivityReadsLowAtEveryTimeSinceTheBolus() throws {
        let truth = TherapySettings(insulinSensitivity: 2, carbRatio: 10, insulinDuration: 5 * 3600, insulinPeak: 75 * 60)
        let history = corrections(days: 3, truth: truth)
        let result = backtestForecast(history.data, therapy: believed, excludedDays: [], interval: history.date(0)...history.date(70), calendar: .utc)
        for age in BolusAge.allCases {
            #expect(try #require(result.byBolusAge[age]?[60]).bias < 0, "\(age)")
        }
    }

    @Test func insulinFasterThanBelievedReadsHighFirstAndLowLater() throws {
        let truth = TherapySettings(insulinSensitivity: 3, carbRatio: 10, insulinDuration: 4 * 3600, insulinPeak: 45 * 60)
        let history = corrections(days: 3, truth: truth)
        let result = backtestForecast(history.data, therapy: believed, excludedDays: [], interval: history.date(0)...history.date(70), calendar: .utc)
        #expect(try #require(result.byBolusAge[.underOneHour]?[30]).bias > 0.05)
        #expect(try #require(result.byBolusAge[.twoToThreeHours]?[60]).bias < -0.05)
        #expect(result.byEpisode[.correction]?[60]?.count ?? 0 > 0)
        #expect(result.byEpisode[.quiet]?[60]?.count ?? 0 > 0)
    }

    @Test func aForecastIsNotScoredAcrossABolusItCouldNotKnowAbout() {
        let history = SyntheticHistory(hours: 8, boluses: [(4.25, 2)])
        let result = backtestForecast(history.data, therapy: believed, excludedDays: [], interval: history.date(3.5)...history.date(3.5), calendar: .utc)
        #expect(result.all[60]?.count == 1)
        #expect(result.included[30]?.count == 1)
        #expect(result.included[60] == nil)
    }
}
