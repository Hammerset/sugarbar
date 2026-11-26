import Foundation
import Testing

@testable import SugarbarCore

@Suite struct TherapyVersionTests {
    private let start = Date(timeIntervalSince1970: 1_795_000_000)

    private var settings: Settings {
        var settings = Settings.default
        settings.therapy = TherapySettings(insulinSensitivity: 3, carbRatio: 12, insulinDuration: 5 * 3600, insulinPeak: 75 * 60)
        return settings
    }

    private var proposal: CalibrationProposal {
        var proposed = settings.therapy
        proposed.insulinPeak = 65 * 60
        proposed.insulinSensitivity = 2.6
        return CalibrationProposal(
            computedAt: start,
            changes: [
                .init(quantity: .insulinPeak, current: 75 * 60, proposed: 65 * 60),
                .init(quantity: .insulinSensitivity, current: 3, proposed: 2.6),
            ],
            current: settings.therapy,
            proposed: proposed,
            heldOutError: 0.97,
            proposedHeldOutError: 0.88,
            corrections: 109,
            meals: 0
        )
    }

    private func report(_ proposal: CalibrationProposal?) -> CalibrationReport {
        CalibrationReport(
            computedAt: start, fittedRange: start...start, heldOutRange: start...start, insulin: nil, carbs: nil, morning: nil,
            drift: QuietDrift(night: nil, day: nil, nightHours: 0, dayHours: 0, episodes: 0), bolusAge: [:], proposal: proposal
        )
    }

    @Test func approvingAppliesEveryChangeAndKeepsTheOldSettingsAsABaselineVersion() throws {
        let approved = settings.approving(proposal, at: start)
        #expect(approved.therapy.insulinPeak == 65 * 60)
        #expect(approved.therapy.insulinSensitivity == 2.6)
        #expect(approved.therapy.carbRatio == 12)
        #expect(approved.therapyLearning.versions.map(\.therapy) == [settings.therapy, approved.therapy])
        #expect(approved.therapyLearning.versions[0].isBaseline)
        #expect(approved.therapyLearning.changes.map(\.quantity) == [.insulinSensitivity, .insulinPeak])
        #expect(approved.visibleProposal(report(proposal)) == nil)
    }

    @Test func rollingBackRestoresAVersionAsANewOne() throws {
        let approved = settings.approving(proposal, at: start)
        let baseline = try #require(approved.therapyLearning.versions.first)
        let rolledBack = approved.rollingBack(to: baseline, at: start.addingTimeInterval(86400))
        #expect(rolledBack.therapy == settings.therapy)
        #expect(rolledBack.therapyLearning.versions.count == 3)
        #expect(rolledBack.therapyLearning.versions.last?.evidence == "Rolled back to the settings before versions were kept")
    }

    @Test func aRejectedProposalStaysHiddenUntilItsValuesChange() {
        #expect(settings.visibleProposal(report(proposal)) == proposal)
        let rejected = settings.rejecting(proposal)
        #expect(rejected.visibleProposal(report(proposal)) == nil)

        var next = proposal.changes
        next[1] = .init(quantity: .insulinSensitivity, current: 3, proposed: 2.7)
        let moved = CalibrationProposal(
            computedAt: start, changes: next, current: proposal.current, proposed: proposal.proposed,
            heldOutError: 1, proposedHeldOutError: 0.9, corrections: 9, meals: 0
        )
        #expect(rejected.visibleProposal(report(moved)) == moved)
    }

    @Test func aProposalMadeAgainstOtherSettingsIsNotShown() {
        let edited = settings.editingTherapy({ var t = settings.therapy; t.insulinPeak = 70 * 60; return t }(), at: start)
        #expect(edited.visibleProposal(report(proposal)) == nil)
        #expect(edited.therapyLearning.versions.count == 2)
    }

    @Test func eachVersionIsScoredOnTheForecastsLoggedWhileItWasInPlace() {
        let versions = [
            TherapyVersion(date: .distantPast, therapy: settings.therapy, evidence: ""),
            TherapyVersion(date: start.addingTimeInterval(3600), therapy: settings.therapy, evidence: ""),
        ]
        let readings = (0...48).map { Reading(value: 6, timestamp: start.addingTimeInterval(Double($0) * 300), trend: .stable) }
        func entry(_ minutes: Double, predicting value: Double) -> ForecastLogEntry {
            ForecastLogEntry(
                date: start.addingTimeInterval(minutes * 60), glucose: 6, predicted: forecastLogOffsets.map { _ in value },
                insulinOnBoard: 0, carbsOnBoard: 0, trendRate: nil, unexplainedRate: nil, carbFactor: 1,
                meals: [], boluses: [], therapy: settings.therapy, lowThreshold: 3.9
            )
        }
        let scores = versionAccuracy(
            versions, log: [entry(0, predicting: 7), entry(30, predicting: 7), entry(70, predicting: 6.5)],
            readings: readings, alerts: .default, now: start.addingTimeInterval(4 * 3600)
        )
        #expect(scores[versions[0].id]?.error(atMinute: 30).meanAbsoluteError == 1)
        #expect(scores[versions[0].id]?.forecastCount == 2)
        #expect(scores[versions[1].id]?.error(atMinute: 30).meanAbsoluteError == 0.5)
    }

    @Test func learningSavedBeforeVersionsDecodesWithNone() throws {
        let old = Data(#"{"changes":[],"dismissed":[],"excludedDays":[]}"#.utf8)
        let learning = try JSONDecoder().decode(TherapyLearning.self, from: old)
        #expect(learning.versions.isEmpty)
        #expect(learning.rejectedProposal == nil)
    }
}
