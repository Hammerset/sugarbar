import Foundation
import Testing

@testable import SugarbarCore

@Suite struct CalibrationFitTests {
    private let believed = TherapySettings(insulinSensitivity: 3, carbRatio: 10, insulinDuration: 5 * 3600, insulinPeak: 75 * 60)

    /// Corrections of an unlogged rise every 12 hours, and a logged, pre-bolused meal at 18:00 every other day.
    private func history(days: Int, truth: TherapySettings, mealBolusRatio: Double = 10) -> SyntheticHistory {
        let corrections = (0..<days).flatMap { day in [(Double(day) * 24 + 3, 1.5), (Double(day) * 24 + 11, 1.0)] }
        let meals = stride(from: 0, to: days, by: 2).map { (Double($0) * 24 + 18, 50.0) }
        return SyntheticHistory(
            hours: Double(days) * 24,
            truth: truth,
            boluses: corrections + meals.map { ($0.0 - 0.25, $0.1 / mealBolusRatio) },
            meals: meals,
            rises: corrections.map { ($0.0 - 1, $0.1 * truth.insulinSensitivity!) }
        )
    }

    private var coarse: CalibrationOptions {
        var options = CalibrationOptions.default
        options.spacing = 20 * 60
        options.peaks = [45, 55, 65, 75, 85].map { $0 * 60 }
        options.durations = [4, 5, 6].map { $0 * 3600 }
        options.sensitivities = [2.0, 2.4, 2.6, 2.8, 3.0, 3.4]
        options.carbRatioShares = [0.7, 0.8, 0.9, 1.0, 1.1]
        options.absorptionTimes = [3 * 3600]
        return options
    }

    @Test func itFindsTheTrueInsulinCurveAndProposesAStepTowardItThatHelpsOnHeldOutDays() throws {
        let truth = TherapySettings(insulinSensitivity: 2.4, carbRatio: 10, insulinDuration: 4 * 3600, insulinPeak: 55 * 60)
        let synthetic = history(days: 21, truth: truth)
        let report = calibrateForecast(synthetic.data, therapy: believed, excludedDays: [], options: coarse, calendar: .utc)

        let insulin = try #require(report.insulin)
        #expect(insulin.best.insulinPeak == 55 * 60)
        #expect(insulin.best.insulinDuration == 4 * 3600)
        #expect(insulin.best.insulinSensitivity == 2.4)
        #expect(try #require(insulin.heldOut[insulin.best]).meanAbsoluteError < 0.05)

        let proposal = try #require(report.proposal)
        for change in proposal.changes {
            #expect(abs(change.proposed - change.current) <= 0.15 * change.current + 1e-9, "\(change.quantity)")
        }
        #expect(proposal.proposed.insulinPeak == 65 * 60)
        #expect(proposal.proposed.insulinSensitivity == 2.6)
        #expect(proposal.proposedHeldOutError < proposal.heldOutError * 0.9)
        #expect(proposal.corrections >= 8)
    }

    @Test func withTheTrueSettingsAlreadyInPlaceThereIsNothingToPropose() {
        let synthetic = history(days: 21, truth: believed)
        let report = calibrateForecast(synthetic.data, therapy: believed, excludedDays: [], options: coarse, calendar: .utc)
        #expect(report.insulin?.best == believed)
        #expect(report.proposal == nil)
    }

    @Test func carbRatioIsFittedOnMealsWithTheInsulinCurveHeldAtItsFit() throws {
        let truth = TherapySettings(insulinSensitivity: 3, carbRatio: 8, insulinDuration: 5 * 3600, insulinPeak: 75 * 60)
        let synthetic = history(days: 30, truth: truth, mealBolusRatio: 8)
        var options = coarse
        options.minimumMeals = 5
        let report = calibrateForecast(synthetic.data, therapy: believed, excludedDays: [], options: options, calendar: .utc)
        let carbs = try #require(report.carbs)
        #expect(carbs.best.carbRatio == 8)
        #expect(report.proposal?.proposed.carbRatio == 9)
        #expect(report.proposal?.meals ?? 0 >= 5)
    }

    @Test func quietDriftSplitsNightFromDay() throws {
        let synthetic = SyntheticHistory(
            start: Date(timeIntervalSince1970: 1_795_392_000), hours: 24, boluses: [(6, 1)],
            extra: { hour in 0.3 * min(hour, 6) }
        )
        let drift = quietDrift(synthetic.labels(), boluses: synthetic.doses, calendar: .utc)
        #expect(drift.episodes == 2)
        #expect(abs(try #require(drift.night) - 0.3) < 0.01)
        #expect(abs(try #require(drift.day)) < 0.01)
        #expect(abs(drift.nightHours - 5.9) < 0.1)
    }
}
