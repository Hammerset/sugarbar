import Foundation
import Testing

@testable import SugarbarCore

private let oslo = TimeZone(identifier: "Europe/Oslo")!
// Thu 2026-11-12 14:07 in Oslo (UTC+1).
private let now = Date(timeIntervalSince1970: 1_794_488_820)

@Suite struct ClaudeSnapshotTests {
    private let settings = Settings(
        thresholds: .standard,
        pollCadence: 60,
        selectedPatientId: "patient-123",
        disclaimerAcknowledged: true,
        therapy: TherapySettings(insulinSensitivity: 2.5, carbRatio: 10)
    )

    private func snapshot(
        _ window: HistoryWindow,
        meals extra: [Meal] = [],
        settings: Settings? = nil,
        empty: Bool = false
    ) -> String {
        let history = syntheticHistory(days: empty ? 0 : 100, now: now)
        let readings = empty ? [] : history.readings
        let doses = empty ? [] : history.doses
        let therapy = (settings ?? self.settings).therapy
        let thresholds = (settings ?? self.settings).thresholds
        let meals = (empty ? [] : history.meals) + extra
        let forecast = SugarbarCore.forecast(
            readings: readings.filter { $0.timestamp > now.addingTimeInterval(-6 * 3600) },
            doses: doses, meals: meals, therapy: therapy, thresholds: thresholds, sensorActivation: nil, now: now
        )
        return claudeSnapshot(
            readings: readings, doses: doses, meals: meals,
            latest: readings.last, sensorActivation: nil,
            forecast: forecast, forecastReview: nil,
            settings: settings ?? self.settings,
            suggestions: [TherapySuggestion(quantity: .carbRatio, current: 10, suggested: 9, episodeCount: 12, days: 14)],
            window: window, now: now, timeZone: oslo
        )
    }

    private func rows(_ text: String, after heading: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix(heading) }) else { return [] }
        return Array(lines[(start + 1)...].prefix { !$0.isEmpty && !$0.hasPrefix("## ") })
    }

    @Test func fourHourViewHasFiveMinuteRowsEveryDoseAndStaysCompact() {
        let text = snapshot(.fourHours)
        #expect(text.contains("Mean per 5 min, one row per hour"))
        let hourRows = rows(text, after: "## Glucose in view").filter { $0.hasPrefix("Thu ") }
        #expect(hourRows.map { $0.prefix(9) } == ["Thu 10:00", "Thu 11:00", "Thu 12:00", "Thu 13:00", "Thu 14:00"])
        #expect(hourRows[1].split(separator: " ").count == 2 + 12)
        #expect(text.contains("- Thu 12:00 bolus 6 u (NovoRapid, pen)"))
        #expect(text.contains("- Thu 13:37 bolus 2 u (entered in sugarbar, pen not yet synced)"))
        #expect(text.contains("Total in view: bolus 8 u, basal 0 u."))
        #expect(text.contains("Glucose 10.9 → stable, +0.00 mmol/L per min, read 14:07 (just now)."))
        #expect(text.contains("+30 min"))
        #expect(text.contains("NOT accepted"))
        #expect(!text.contains("patient-123"))
        #expect(text.count < 7_000)
    }

    @Test func thinsByRange() {
        #expect(snapshot(.day).contains("Mean per 15 min"))
        let threeDays = snapshot(.threeDays)
        #expect(threeDays.contains("Hourly since Mon 14:07"))
        #expect(!threeDays.contains("Per day before"))
        let ninety = snapshot(.ninetyDays)
        #expect(ninety.contains("Per day before Tue 2026-11-10"))
        #expect(ninety.contains("Hourly since Tue 00:00"))
        #expect(rows(ninety, after: "Per day before").filter { $0.dropFirst(4).hasPrefix("2026-") }.count == 88)
        #expect(ninety.count < 24_000)
    }

    @Test func longViewListsRecentEventsAndTotalsTheWholeRange() {
        let text = snapshot(.week)
        let doses = rows(text, after: "## Insulin in view").filter { $0.hasPrefix("- ") }
        #expect(doses.allSatisfy { $0.hasPrefix("- Tue") || $0.hasPrefix("- Wed") || $0.hasPrefix("- Thu") })
        #expect(text.contains("Total in view: bolus 110.5 u, basal 126 u."))
        #expect(text.contains("Total carbs in view: 749 g."))
        #expect(text.contains("Last basal: 18 u at Wed 22:00."))
    }

    @Test func plannedMealsAreListedApartAndNotCounted() {
        let planned = Meal(
            timestamp: now.addingTimeInterval(45 * 60), carbsGrams: 80, summary: "Pizza",
            fatGrams: 30, carbAbsorption: .slow, state: .planned,
            plan: MealPlan(carbsGrams: 80, units: 8, takenUnits: 0)
        )
        let text = snapshot(.fourHours, meals: [planned])
        #expect(text.contains("Total carbs in view: 62 g."))
        #expect(rows(text, after: "Planned, not eaten yet:") == [
            "- Thu 14:52 80 g carbs \"Pizza\" (fat 30 g; logged as slow / fatty absorption), dose planned 8 u, 0 u logged so far",
        ])
    }

    @Test func saysWhatIsMissing() {
        var incomplete = settings
        incomplete.therapy = TherapySettings()
        let text = snapshot(.fourHours, settings: incomplete, empty: true)
        #expect(text.contains("No current Reading."))
        #expect(text.contains("No Readings in view."))
        #expect(text.contains("No Doses recorded in view."))
        #expect(text.contains("No Meals logged in view."))
        #expect(text.contains("No Forecast: insulin sensitivity and carb ratio are not both set."))
        #expect(text.contains("carb ratio not set; insulin sensitivity not set"))
    }

    @Test func questionGoesFirst() {
        let history = syntheticHistory(days: 1, now: now)
        let text = claudeSnapshot(
            readings: history.readings, doses: [], meals: [], latest: history.readings.last, sensorActivation: nil,
            forecast: nil, forecastReview: nil, settings: settings, suggestions: [],
            window: .fourHours, now: now, timeZone: oslo, includesQuestion: true
        )
        #expect(text.hasPrefix(claudeSnapshotQuestion + "\n\n# Sugarbar snapshot, last 4h"))
    }
}

