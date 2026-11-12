import Foundation
import Testing

@testable import SugarbarCore

@Suite struct AlertPolicyTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private let enabled = AlertSettings(
        isEnabled: true,
        enabledLevels: Set(AlertLevel.allCases),
        lowRepeatInterval: 20 * 60,
        highRepeatInterval: 60 * 60
    )

    private func step(
        _ value: Double,
        at minutes: Double,
        state: AlertState,
        settings: AlertSettings? = nil,
        readingAge: TimeInterval = 60,
        sensorActivation: Date? = nil
    ) -> AlertDecision {
        let settings = settings ?? enabled
        let now = start.addingTimeInterval(minutes * 60)
        let reading = Reading(value: value, timestamp: now.addingTimeInterval(-readingAge), trend: .falling)
        let conditions = glucoseAlertConditions(
            latest: reading, sensorActivation: sensorActivation, now: now,
            thresholds: .standard, settings: settings
        )
        return evaluateAlerts(conditions: conditions, state: state, now: now, snoozedUntil: settings.snoozedUntil)
    }

    @Test func entersLowWithValueAndTrendInTitle() {
        let decision = step(3.6, at: 0, state: AlertState())
        #expect(decision.notifications.map(\.title) == ["Low: 3.6 ↘"])
        #expect(decision.notifications.first?.reason == .entered)
    }

    @Test func staysQuietWithinRepeatIntervalThenRepeats() {
        let first = step(3.6, at: 0, state: AlertState())
        let quiet = step(3.5, at: 10, state: first.state)
        #expect(quiet.notifications.isEmpty)
        let repeated = step(3.5, at: 20, state: quiet.state)
        #expect(repeated.notifications.map(\.reason) == [.repeated])
        #expect(repeated.notifications.first?.title == "Still low: 3.5 ↘")
    }

    @Test func highUsesItsOwnRepeatInterval() {
        let first = step(11, at: 0, state: AlertState())
        #expect(step(11, at: 59, state: first.state).notifications.isEmpty)
        #expect(step(11, at: 60, state: first.state).notifications.count == 1)
    }

    @Test func escalatesToUrgentButNotBackDown() {
        let low = step(3.6, at: 0, state: AlertState())
        let urgent = step(2.8, at: 5, state: low.state)
        #expect(urgent.notifications.map(\.reason) == [.escalated])
        #expect(urgent.notifications.first?.isUrgent == true)
        #expect(step(3.5, at: 10, state: urgent.state).notifications.isEmpty)
    }

    @Test func returnToRangeResetsAndResolves() {
        let low = step(3.6, at: 0, state: AlertState())
        let back = step(5.5, at: 5, state: low.state)
        #expect(back.notifications.isEmpty)
        #expect(back.resolvedFamilies == [GlucoseAlertFamily.low])
        #expect(back.state == AlertState())
        #expect(step(3.7, at: 6, state: back.state).notifications.map(\.reason) == [.entered])
    }

    @Test func staleReadingNeitherAlertsNorResets() {
        let low = step(3.6, at: 0, state: AlertState())
        let stale = step(5.5, at: 30, state: low.state, readingAge: 10 * 60)
        #expect(stale.notifications.isEmpty)
        #expect(stale.state == low.state)
        #expect(step(3.0, at: 0, state: AlertState(), readingAge: 10 * 60).notifications.isEmpty)
    }

    @Test func noAlertDuringWarmUp() {
        let decision = step(
            3.0, at: 0, state: AlertState(), readingAge: 10 * 60,
            sensorActivation: start.addingTimeInterval(-10 * 60)
        )
        #expect(decision.notifications.isEmpty)
    }

    @Test func snoozeSuppressesWithoutRecordingSoItFiresAfterwards() {
        var snoozed = enabled
        snoozed.snoozedUntil = start.addingTimeInterval(30 * 60)
        let during = step(3.6, at: 0, state: AlertState(), settings: snoozed)
        #expect(during.notifications.isEmpty)
        #expect(step(3.6, at: 31, state: during.state, settings: snoozed).notifications.map(\.reason) == [.entered])
    }

    @Test func disabledUrgentLevelFallsBackToItsSibling() {
        var settings = enabled
        settings.enabledLevels = [.low]
        #expect(step(2.5, at: 0, state: AlertState(), settings: settings).notifications.map(\.title) == ["Low: 2.5 ↘"])
        settings.enabledLevels = [.urgentLow]
        #expect(step(3.6, at: 0, state: AlertState(), settings: settings).notifications.isEmpty)
    }

    @Test func offByDefaultAndHighsOffOnceEnabled() {
        #expect(step(2.5, at: 0, state: AlertState(), settings: .default).notifications.isEmpty)
        var settings = AlertSettings.default
        settings.isEnabled = true
        #expect(step(15, at: 0, state: AlertState(), settings: settings).notifications.isEmpty)
        #expect(step(2.5, at: 0, state: AlertState(), settings: settings).notifications.count == 1)
    }

    @Test func independentFamiliesDebounceSeparately() {
        let other = AlertCondition(
            family: "forecast.low", rank: 0, repeatInterval: 600,
            title: "t", repeatTitle: "r", body: "b", isUrgent: false
        )
        let low = step(3.6, at: 0, state: AlertState())
        let now = start.addingTimeInterval(60)
        let bandOnly = glucoseAlertConditions(
            latest: Reading(value: 3.6, timestamp: now, trend: .falling), sensorActivation: nil,
            now: now, thresholds: .standard, settings: enabled
        ) ?? []
        let decision = evaluateAlerts(conditions: bandOnly + [other], state: low.state, now: now)
        #expect(decision.notifications.map(\.family) == ["forecast.low"])
    }
}

@Suite struct AlertSettingsStorageTests {
    @Test func decodesWhenFieldsAreMissing() throws {
        let decoded = try JSONDecoder().decode(AlertSettings.self, from: Data(#"{"isEnabled":true}"#.utf8))
        var expected = AlertSettings.default
        expected.isEnabled = true
        #expect(decoded == expected)
    }

    @Test func storedSettingsWithoutPredictionsGetDefaultsAndLeadsAreClamped() throws {
        let json = #"{"isEnabled":true,"enabledLevels":["low"],"lowRepeatInterval":1200,"highRepeatInterval":3600,"predictedHighLead":99999}"#
        let decoded = try JSONDecoder().decode(AlertSettings.self, from: Data(json.utf8))
        #expect(decoded.predictsLow)
        #expect(decoded.predictedLowLead == 30 * 60)
        #expect(!decoded.predictsHigh)
        #expect(decoded.predictedHighLead == AlertSettings.predictionLeadRange.upperBound)
    }

    @Test func roundTripsThroughSettingsStore() {
        let suite = "sugarbar.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = UserDefaultsSettingsStore(defaults: defaults)
        #expect(store.load().alerts == .default)
        var settings = Settings.default
        settings.alerts.isEnabled = true
        settings.alerts.enabledLevels = [.urgentLow, .urgentHigh]
        store.save(settings)
        #expect(store.load().alerts == settings.alerts)
    }
}

@Suite struct ForecastAlertTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private var settings: AlertSettings {
        var settings = AlertSettings.default
        settings.isEnabled = true
        settings.predictsHigh = true
        return settings
    }

    private func conditions(
        value: Double,
        lowIn: Double? = nil,
        highIn: Double? = nil,
        settings: AlertSettings? = nil,
        alerting: Set<String> = []
    ) -> [AlertCondition] {
        let latest = Reading(value: value, timestamp: now.addingTimeInterval(-60), trend: .falling)
        let forecast = Forecast(
            points: [ForecastPoint(date: latest.timestamp, value: value)],
            insulinOnBoard: 0,
            carbsOnBoard: 0,
            lowCrossing: lowIn.map { now.addingTimeInterval($0 * 60) },
            highCrossing: highIn.map { now.addingTimeInterval($0 * 60) }
        )
        return forecastAlertConditions(
            forecast: forecast, latest: latest, now: now, thresholds: .standard,
            settings: settings ?? self.settings, alerting: alerting
        )
    }

    @Test func warnsOnlyForCrossingsInsideTheirLeadTime() {
        let low = conditions(value: 4.6, lowIn: 19)
        #expect(low.map(\.family) == [ForecastAlertFamily.low])
        #expect(low.first?.title == "Heading low: 4.6 ↘")
        #expect(low.first?.body == "Predicted below 3.9 in about 20 min. Check, and consider carbs. Sugarbar is not a medical device.")
        #expect(conditions(value: 4.6, lowIn: 45).isEmpty)
        #expect(conditions(value: 9, highIn: 55).map(\.family) == [ForecastAlertFamily.high])
        #expect(conditions(value: 9, highIn: 65).isEmpty)
    }

    @Test func quietWhenAlreadyPastTheThreshold() {
        #expect(conditions(value: 3.6, lowIn: 10).isEmpty)
        #expect(conditions(value: 11, highIn: 10).isEmpty)
    }

    @Test func predictedHighIsOffByDefault() {
        var defaults = AlertSettings.default
        defaults.isEnabled = true
        #expect(conditions(value: 9, highIn: 10, settings: defaults).isEmpty)
        #expect(conditions(value: 4.6, lowIn: 10, settings: .default).isEmpty)
    }

    @Test func staysOnPastTheLeadOnceWarned() {
        #expect(conditions(value: 4.6, lowIn: 40, alerting: [ForecastAlertFamily.low]).count == 1)
        #expect(conditions(value: 4.6, lowIn: 70, alerting: [ForecastAlertFamily.low]).isEmpty)
    }
}
