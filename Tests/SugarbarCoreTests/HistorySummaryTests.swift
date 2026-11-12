import Foundation
import Testing

@testable import SugarbarCore

private let oslo = TimeZone(identifier: "Europe/Oslo")!
// Thu 2026-11-12 14:07 in Oslo (UTC+1).
private let now = Date(timeIntervalSince1970: 1_794_488_820)

/// 14 days of 1-minute Readings on a daily sine with a dip below low around 03:00,
/// three boluses and a basal per day, and two logged meals per day.
func syntheticHistory(days: Int, now: Date) -> (readings: [Reading], doses: [InsulinDose], meals: [Meal]) {
    let start = now.addingTimeInterval(-Double(days) * 86400)
    var readings: [Reading] = []
    var minute = 0.0
    while start.addingTimeInterval(minute * 60) <= now {
        let date = start.addingTimeInterval(minute * 60)
        let hourOfDay = (date.timeIntervalSince1970 + 3600).truncatingRemainder(dividingBy: 86400) / 3600
        let value = 7.5 + 3.5 * sin((hourOfDay - 9) / 24 * 2 * .pi) - (abs(hourOfDay - 3) < 0.4 ? 1.2 : 0)
        readings.append(Reading(value: value, timestamp: date, trend: .stable))
        minute += 1
    }
    var doses: [InsulinDose] = []
    var meals: [Meal] = []
    var day = start
    while day <= now {
        let midnight = day.addingTimeInterval(-((day.timeIntervalSince1970 + 3600).truncatingRemainder(dividingBy: 86400)))
        for (hour, units) in [(7.5, 4.0), (12.0, 6.0), (18.5, 5.5)] {
            doses.append(InsulinDose(kind: .bolus, units: units, timestamp: midnight.addingTimeInterval(hour * 3600), insulinName: "NovoRapid", deviceName: "NovoPen 6"))
        }
        doses.append(InsulinDose(kind: .basal, units: 18, timestamp: midnight.addingTimeInterval(22 * 3600), insulinName: "Tresiba", deviceName: nil))
        meals.append(Meal(timestamp: midnight.addingTimeInterval(7.6 * 3600), carbsGrams: 45, summary: "Oatmeal with berries"))
        meals.append(Meal(timestamp: midnight.addingTimeInterval(12.1 * 3600), carbsGrams: 62, summary: "Spaghetti bolognese,\nlarge plate"))
        day = day.addingTimeInterval(86400)
    }
    return (readings, doses, meals)
}

@Suite struct HistorySummaryTests {
    private let therapy = TherapySettings(insulinSensitivity: 2.5, carbRatio: 10)

    private func summary(days: Int = 14) -> String {
        let history = syntheticHistory(days: 20, now: now)
        return historySummary(
            readings: history.readings, doses: history.doses, meals: history.meals,
            thresholds: .standard, therapy: therapy, now: now, days: days, timeZone: oslo
        )
    }

    @Test func statesUnitsTimeZoneAndSettings() {
        let text = summary()
        #expect(text.contains("glucose mmol/L"))
        #expect(text.contains("time zone Europe/Oslo (UTC+01:00)"))
        #expect(text.contains("Generated Thu 2026-11-12 14:07"))
        #expect(text.contains("insulin sensitivity 2.5 mmol/L per u; carb ratio 10 g per u"))
    }

    @Test func lastDayIsFifteenMinuteRowsWithLocalTimedEvents() {
        let text = summary()
        let section = text.components(separatedBy: "## Last 24 hours")[1].components(separatedBy: "## Daily")[0]
        let rows = section.split(separator: "\n").filter { $0.range(of: #"^\w{3} \d{2}:00  "#, options: .regularExpression) != nil }
        #expect(rows.count == 25)
        #expect(rows.first?.hasPrefix("Wed 14:00") == true)
        #expect(rows.last?.split(separator: " ").count == 3)
        #expect(rows.dropLast().allSatisfy { $0.split(separator: " ").count == 6 })
        #expect(section.contains("- Wed 18:30 bolus 5.5 u (NovoRapid, pen)"))
        #expect(section.contains("- Wed 22:00 basal 18 u (Tresiba, logged by hand)"))
        #expect(section.contains("- Thu 07:36 meal 45 g carbs \"Oatmeal with berries\""))
        #expect(section.contains("- Thu 02:36 low until 03:24, lowest 2.8 at 03:00"))
        #expect(!section.contains("Tue "))
    }

    @Test func dailyLinesCarryStatsTotalsAndMeals() throws {
        let text = summary()
        let daily = text.components(separatedBy: "## Daily summaries")[1].components(separatedBy: "## Time-of-day")[0]
        let lines = daily.split(separator: "\n").filter { $0.hasPrefix("- ") }
        #expect(lines.count == 14)
        #expect(lines.first?.hasPrefix("- Fri 2026-10-30: ") == true)
        let full = try #require(lines.first { $0.hasPrefix("- Tue 2026-11-10") })
        #expect(full.contains("coverage 100%"))
        #expect(full.contains("lows 1: 02:36 (lowest 2.8)"))
        #expect(full.contains("bolus 15.5 u (07:30 4, 12:00 6, 18:30 5.5), basal 18 u"))
        #expect(full.contains("carbs 107 g (07:36 45 g \"Oatmeal with berries\", 12:06 62 g \"Spaghetti bolognese, large plate\")"))
        #expect(full.contains("TIR urgent low "))
    }

    @Test func profileHasEveryHourWithLowsAtNight() throws {
        let text = summary()
        let profile = text.components(separatedBy: "## Time-of-day profile")[1]
        let rows = profile.split(separator: "\n").filter { $0.range(of: #"^\d{2}: "#, options: .regularExpression) != nil }
        #expect(rows.count == 24)
        let three = try #require(rows.first { $0.hasPrefix("03:") })
        #expect(!three.contains("low 0%"))
        let noon = try #require(rows.first { $0.hasPrefix("12:") })
        #expect(noon.contains("low 0%"))
        #expect(noon.hasSuffix("14 d"))
    }

    @Test func fourteenDaysStaysWithinTokenBudget() {
        // ~3.5 characters per token for this mix of numbers and words; 15k tokens ≈ 52k characters.
        #expect(summary().count < 52_000)
        #expect(summary(days: 30).count > summary().count)
    }

    @Test func emptyHistoryStillDescribesTheGaps() {
        let text = historySummary(readings: [], doses: [], meals: [], thresholds: .standard, therapy: .default, now: now, days: 3, timeZone: oslo)
        #expect(text.contains("No Readings in this span."))
        #expect(text.contains("insulin sensitivity not set"))
        #expect(text.contains("- none recorded"))
        #expect(text.contains("no Readings; lows 0; bolus 0 u, basal 0 u; carbs 0 g"))
    }

    @Test func lowEpisodesMergeShortGaps() {
        let base = Date(timeIntervalSince1970: 0)
        func reading(_ minutes: Double, _ value: Double) -> Reading {
            Reading(value: value, timestamp: base.addingTimeInterval(minutes * 60), trend: .stable)
        }
        let readings = [reading(0, 4.5), reading(5, 3.6), reading(15, 3.2), reading(25, 4.1), reading(30, 3.8), reading(60, 3.7)]
        let episodes = lowEpisodes(readings, below: 3.9)
        #expect(episodes.count == 2)
        #expect(episodes[0].start == base.addingTimeInterval(300))
        #expect(episodes[0].end == base.addingTimeInterval(1800))
        #expect(episodes[0].nadir.value == 3.2)
    }
}
