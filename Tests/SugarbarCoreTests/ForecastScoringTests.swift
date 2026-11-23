import Foundation
import Testing

@testable import SugarbarCore

@Suite struct ForecastScoringTests {
    private let start = Date(timeIntervalSince1970: 1_699_956_000)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func reading(_ minutes: Double, _ value: Double) -> Reading {
        Reading(value: value, timestamp: start.addingTimeInterval(minutes * 60), trend: .notDetermined)
    }

    /// A Forecast at `minutes` that predicts `predict(offset)` at each logged offset.
    private func entry(
        _ minutes: Double,
        glucose: Double = 7,
        trend: Double? = 0,
        meals: [LoggedMeal] = [],
        boluses: [LoggedBolus] = [],
        predict: (Int) -> Double
    ) -> ForecastLogEntry {
        ForecastLogEntry(
            date: start.addingTimeInterval(minutes * 60),
            glucose: glucose,
            predicted: forecastLogOffsets.map(predict),
            insulinOnBoard: 0,
            carbsOnBoard: 0,
            trendRate: trend,
            unexplainedRate: 0,
            carbFactor: 1,
            meals: meals,
            boluses: boluses,
            therapy: TherapySettings(insulinSensitivity: 3, carbRatio: 10),
            lowThreshold: 3.9
        )
    }

    private var rules: AlertScoringRules { AlertScoringRules(alerts: .default) }

    @Test func actualGlucoseInterpolatesShortGapsAndRefusesLongOnes() {
        let readings = [reading(0, 6), reading(10, 8), reading(40, 5), reading(45, 5.5)]
        #expect(actualGlucose(at: start.addingTimeInterval(60), sortedReadings: readings) == 6)
        #expect(abs((actualGlucose(at: start.addingTimeInterval(5 * 60), sortedReadings: readings) ?? 0) - 7) < 1e-9)
        #expect(actualGlucose(at: start.addingTimeInterval(25 * 60), sortedReadings: readings) == nil)
        #expect(actualGlucose(at: start.addingTimeInterval(60 * 60), sortedReadings: readings) == nil)
        let clamped = [reading(0, 6), Reading(value: mmolPerL(fromMgPerDl: 40), timestamp: start.addingTimeInterval(600), trend: .notDetermined)]
        #expect(actualGlucose(at: start.addingTimeInterval(300), sortedReadings: clamped) == nil)
    }

    @Test func errorsPerHorizonSkipGapsAndTheFuture() {
        var readings = stride(from: 0.0, through: 200, by: 5).map { reading($0, 7) }
        readings.removeAll { $0.timestamp > start.addingTimeInterval(50 * 60) && $0.timestamp < start.addingTimeInterval(75 * 60) }
        let entries = [
            entry(0) { minute in 7 + Double(minute) / 30 },
            entry(5) { minute in 7 - Double(minute) / 30 },
        ]
        let card = scoreForecasts(entries, readings: readings, rules: rules, now: start.addingTimeInterval(100 * 60), calendar: calendar)
        let thirty = card.error(atMinute: 30)
        #expect(thirty.count == 2)
        #expect(abs(thirty.meanAbsoluteError - 1) < 1e-9)
        #expect(abs(thirty.bias) < 1e-9)
        #expect(card.error(atMinute: 60).count == 0)
        #expect(card.error(atMinute: 120).count == 0)
        let fifteen = card.error(atMinute: 15)
        #expect(abs(fifteen.meanAbsoluteError - 0.5) < 1e-9)
    }

    @Test func situationsSplitByMealCorrectionAndNight() {
        let slowMeal = entry(0, meals: [LoggedMeal(minutesAgo: 90, carbsGrams: 80, absorption: .slow)], boluses: [LoggedBolus(minutesAgo: 95, units: 6)]) { _ in 7 }
        let correction = entry(0, meals: [LoggedMeal(minutesAgo: 300, carbsGrams: 40, absorption: .normal)], boluses: [LoggedBolus(minutesAgo: 60, units: 2)]) { _ in 7 }
        let mealBolusOnly = entry(0, meals: [LoggedMeal(minutesAgo: 260, carbsGrams: 40, absorption: .normal)], boluses: [LoggedBolus(minutesAgo: 230, units: 4)]) { _ in 7 }
        let night = entry(-8 * 60) { _ in 7 }
        #expect(forecastSituation(slowMeal, calendar: calendar) == .afterMeal(.slow))
        #expect(forecastSituation(correction, calendar: calendar) == .afterCorrection)
        #expect(forecastSituation(mealBolusOnly, calendar: calendar) == .quiet)
        #expect(forecastSituation(night, calendar: calendar) == .overnight)
    }

    @Test func lowWarningsCountHitsFalseAlarmsMissesAndLeadTime() {
        var readings = stride(from: 0.0, through: 400, by: 5).map { reading($0, 6) }
        func set(_ range: ClosedRange<Double>, _ value: Double) {
            readings = readings.map { range.contains($0.timestamp.timeIntervalSince(start) / 60) ? reading($0.timestamp.timeIntervalSince(start) / 60, value) : $0 }
        }
        set(40...60, 3.5)
        set(300...310, 3.6)
        var entries = stride(from: 0.0, through: 380, by: 5).map { minutes in entry(minutes) { _ in 6 } }
        func warn(at minutes: Double) {
            entries = entries.map { $0.date == start.addingTimeInterval(minutes * 60) ? entry(minutes, glucose: 6) { $0 <= 30 ? 6 - Double($0) / 10 : 3 } : $0 }
        }
        warn(at: 20)
        warn(at: 25)
        warn(at: 150)
        let card = scoreForecasts(entries, readings: readings, rules: rules, now: start.addingTimeInterval(400 * 60), calendar: calendar)
        #expect(card.headingLow.hits == 1)
        #expect(card.headingLow.falseAlarms == 1)
        #expect(card.headingLow.misses == 1)
        #expect(abs((card.headingLow.meanLeadTime ?? 0) - 20 * 60) < 1)
        #expect(card.summaryLine?.hasSuffix("1 of 2 low warnings right") == true)
    }

    @Test func aLowWhileNoForecastsWereMadeIsNotAMiss() {
        let readings = stride(from: 0.0, through: 300, by: 5).map { reading($0, $0 >= 200 && $0 <= 220 ? 3.5 : 6) }
        let entries = stride(from: 0.0, through: 100, by: 5).map { minutes in entry(minutes) { _ in 6 } }
        let card = scoreForecasts(entries, readings: readings, rules: rules, now: start.addingTimeInterval(300 * 60), calendar: calendar)
        #expect(card.headingLow.misses == 0)
    }
}

@Suite struct ForecastLogTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func entry(_ date: Date) -> ForecastLogEntry {
        ForecastLogEntry(
            date: date, glucose: 7.04, predicted: forecastLogOffsets.map { 7 + Double($0) / 100 }, insulinOnBoard: 1.234,
            carbsOnBoard: 20, trendRate: -0.0312, unexplainedRate: nil, carbFactor: 0.8,
            meals: [LoggedMeal(minutesAgo: 30, carbsGrams: 40, absorption: .slow)], boluses: [LoggedBolus(minutesAgo: 32, units: 4)],
            therapy: TherapySettings(insulinSensitivity: 3, carbRatio: 12, slowCarbAbsorptionTime: 6 * 3600), lowThreshold: 3.9
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "forecast-log-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test func entriesAreThinnedToOnePerFiveMinutesAndSurviveARestart() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileForecastLogStore(directory: directory)
        #expect(store.append(entry(now)))
        #expect(!store.append(entry(now.addingTimeInterval(60))))
        #expect(!store.append(entry(now.addingTimeInterval(-600))))
        #expect(store.append(entry(now.addingTimeInterval(5 * 60))))

        let reopened = FileForecastLogStore(directory: directory)
        #expect(!reopened.append(entry(now.addingTimeInterval(6 * 60))))
        let entries = reopened.entries(in: now.addingTimeInterval(-3600)...now.addingTimeInterval(3600))
        #expect(entries.map(\.date) == [now, now.addingTimeInterval(300)])
        #expect(entries[0].therapy.slowCarbAbsorptionTime == 6 * 3600)
        #expect(entries[0].meals.first?.absorption == .slow)
        #expect(entries[0].insulinOnBoard == 1.23)
    }

    @Test func pruningDropsMonthsPastRetention() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileForecastLogStore(directory: directory)
        store.append(entry(now.addingTimeInterval(-130 * 86400)))
        store.append(entry(now.addingTimeInterval(-60 * 86400)))
        store.append(entry(now))
        store.prune(now: now)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        #expect(files.count == 2)
        let kept = FileForecastLogStore(directory: directory).entries(in: now.addingTimeInterval(-200 * 86400)...now)
        #expect(kept.map(\.date) == [now.addingTimeInterval(-60 * 86400), now])
    }
}
