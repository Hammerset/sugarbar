import Foundation
import Testing

@testable import SugarbarCore

/// 16 Nov: bolus 1 u at 15:14, 2 + 3.5 u at 16:31/16:33, 80 g of pasta at 16:50, 1 u at 17:16, then a steep fall the
/// old Forecast drew as a gentle dip. Readings are what a phone opened at that moment has: LibreLinkUp's 15-minute
/// graph points (values from the backfilled History) and the live Reading the user saw.
@Suite struct ForecastReplayTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Oslo")!
        return calendar
    }()
    private let therapy = TherapySettings(insulinSensitivity: 3.0, carbRatio: 12, insulinPeak: 75 * 60, carbAbsorptionTime: 3 * 3600)

    private func at(_ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: hour, minute: minute, second: second))!
    }

    private var doses: [InsulinDose] {
        [(15, 14, 1.0), (16, 31, 2.0), (16, 33, 3.5), (17, 16, 1.0)].map {
            InsulinDose(kind: .bolus, units: $0.2, timestamp: at($0.0, $0.1), insulinName: nil, deviceName: nil)
        }
    }

    private var pasta: Meal { Meal(timestamp: at(16, 50), carbsGrams: 80, summary: "Spaghetti with meat sauce") }

    private func replay(graph: [(Int, Int, Int, Double)], live: Double, trend: Trend, now: Date) throws -> Forecast {
        let readings = graph.map { Reading(value: $0.3, timestamp: at($0.0, $0.1, $0.2), trend: .notDetermined) }
            + [Reading(value: live, timestamp: now, trend: trend)]
        return try #require(forecast(
            readings: readings, doses: doses, meals: [pasta], therapy: therapy,
            thresholds: .standard, sensorActivation: nil, now: now
        ))
    }

    private func value(_ forecast: Forecast, minutesAhead: Double) throws -> Double {
        let start = try #require(forecast.points.first?.date)
        return try #require(forecast.points.first { $0.date == start.addingTimeInterval(minutesAhead * 60) }).value
    }

    @Test func at1737TheForecastFallsTowardFive() throws {
        let now = at(17, 37, 39)
        let result = try replay(
            graph: [(16, 37, 39, 7.49), (16, 52, 39, 7.55), (17, 7, 38, 7.94), (17, 22, 40, 8.05)],
            live: 6.4, trend: .falling, now: now
        )
        #expect(abs(result.insulinOnBoard - 5.4) < 0.1)
        #expect(abs(result.carbsOnBoard - 59) < 1)
        #expect(try value(result, minutesAhead: 20) < 5.0)
        #expect(try value(result, minutesAhead: 30) < 4.5)
        #expect(result.carbAbsorptionFactor < 0.7)
        #expect(result.isUncertain)
    }

    @Test func at1747TheForecastIsUnderFourWithinFifteenMinutesAndWarns() throws {
        let now = at(17, 47, 40)
        let result = try replay(
            graph: [(16, 47, 40, 7.33), (17, 2, 38, 7.6), (17, 17, 39, 8.21), (17, 32, 39, 7.05)],
            live: 4.5, trend: .fallingQuickly, now: now
        )
        #expect(try value(result, minutesAhead: 15) < 4.0)
        #expect(try #require(result.trendRate) < -0.15)

        var settings = AlertSettings.default
        settings.isEnabled = true
        let conditions = forecastAlertConditions(
            forecast: result, latest: Reading(value: 4.5, timestamp: now, trend: .fallingQuickly),
            now: now, thresholds: .standard, settings: settings
        )
        #expect(conditions.contains { $0.family == ForecastAlertFamily.fallingFast })
    }
}
