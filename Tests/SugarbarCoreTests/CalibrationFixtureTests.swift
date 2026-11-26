import Foundation
import Testing

@testable import SugarbarCore

/// Recorded stretches of History (minutes from the window's start, mmol/L, units, grams) that
/// the calibrated settings must predict better than the settings in use before calibration.
private struct ReplayFixture {
    let start: Date
    let windowMinutes: Double
    let readings: [(Double, Double)]
    let boluses: [(Double, Double)]
    var meals: [(Double, Double)] = []

    private func date(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }

    /// Mean absolute error at 15, 30 and 60 min over Forecasts made in the window, leaving out
    /// horizons a later Bolus or Meal reaches.
    func error(_ therapy: TherapySettings) -> Double {
        let data = CalibrationData(
            readings: readings.map { Reading(value: $0.1, timestamp: date($0.0), trend: .notDetermined) },
            doses: boluses.map { InsulinDose(kind: .bolus, units: $0.1, timestamp: date($0.0), insulinName: nil, deviceName: nil) },
            meals: meals.map { Meal(timestamp: date($0.0), carbsGrams: $0.1, summary: "") },
            thresholds: .standard,
            now: date(readings.last!.0)
        )
        let timeline = CalibrationTimeline(readings: data.readings, labels: data.readings.map { _ in .episode(.meal) })
        let times = data.readings.map(\.timestamp).filter { $0 >= start && $0 <= date(windowMinutes) }
        let errors = replayForecasts(data, timeline: timeline, therapy: therapy, times: times)
            .flatMap { forecast in [15, 30, 60].compactMap { forecast.cleanErrors[$0] } }
        return errors.map(abs).reduce(0, +) / Double(errors.count)
    }
}

private func oslo(day: Int, hour: Int, minute: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Oslo")!
    return calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
}

@Suite struct CalibrationFixtureTests {
    private let before = TherapySettings(insulinSensitivity: 3, carbRatio: 12, insulinDuration: 5 * 3600, insulinPeak: 75 * 60, carbAbsorptionTime: 3 * 3600)
    /// The first proposal from 90 days of History: peak 65 min, duration 5.5 h, sensitivity 2.6.
    private var calibrated: TherapySettings {
        var therapy = before
        therapy.insulinPeak = 65 * 60
        therapy.insulinDuration = 5.5 * 3600
        therapy.insulinSensitivity = 2.6
        return therapy
    }

    /// 26 Nov, 2 u at 07:19 with no food: glucose peaks about 20 minutes later and falls faster
    /// than the old curve, then holds near 6.5–7 when the old curve kept falling (0.5 u at 09:29).
    @Test func morningCorrection() {
        let fixture = ReplayFixture(
            start: oslo(day: 26, hour: 7, minute: 19),
            windowMinutes: 231,
            readings: [(-56.6, 6.44), (-51.6, 6.49), (-46.6, 6.66), (-41.6, 6.49), (-36.6, 6.49), (-31.6, 6.83), (-26.6, 7.05), (-21.6, 7.33), (-16.6, 7.66), (-11.6, 7.66), (-6.6, 8.1), (-1.6, 8.27), (3.4, 8.21), (8.4, 8.44), (13.4, 8.94), (18.4, 9.1), (23.4, 9.16), (28.4, 9.1), (33.4, 8.99), (38.4, 8.94), (43.4, 8.55), (48.4, 8.21), (53.4, 8.16), (58.4, 7.71), (63.4, 7.6), (68.4, 7.33), (73.4, 7.27), (78.4, 7.38), (83.5, 6.94), (88.4, 6.55), (93.4, 6.33), (98.4, 6.33), (103.4, 6.33), (108.4, 6.44), (113.4, 6.44), (118.4, 6.55), (123.4, 6.6), (128.4, 6.77), (133.4, 6.83), (138.4, 6.94), (143.4, 6.88), (148.4, 7.05), (153.4, 7.1), (158.4, 6.94), (163.4, 7.05), (168.4, 6.99), (173.4, 6.88), (178.4, 6.6), (183.4, 6.6), (188.4, 6.6), (193.4, 6.55), (198.4, 6.72), (203.4, 6.55), (208.4, 6.66), (213.4, 6.83), (218.4, 6.55), (223.4, 6.72), (228.4, 6.77), (233.4, 6.77), (238.4, 6.83), (243.4, 6.88), (248.4, 6.77), (253.4, 6.83), (258.4, 6.66), (263.4, 6.49), (268.4, 6.27), (273.4, 6.22), (278.4, 5.83), (283.4, 5.61), (288.4, 6.44), (293.4, 6.55), (298.4, 7.55), (303.4, 7.77), (308.4, 8.38), (313.4, 9.6), (318.4, 9.71), (323.4, 9.82), (328.4, 10.05), (333.4, 9.93), (338.4, 10.27), (343.4, 10.16), (348.4, 9.99)],
            boluses: [(0.6, 2), (130.5, 0.5), (239.4, 3.5), (320.3, 1)],
            meals: [(261.7, 55)]
        )
        #expect(fixture.error(calibrated) < fixture.error(before))
    }

    /// 16 Nov, 80 g of pasta at 16:50 with 6.5 u around it: from 17:37 glucose drops from 6.3 to 3.9 in 25 minutes.
    @Test func fastDropAfterPasta() {
        let fixture = ReplayFixture(
            start: oslo(day: 16, hour: 17, minute: 37),
            windowMinutes: 16,
            readings: [(-59.4, 7.49), (-54.4, 7.38), (-49.3, 7.33), (-44.4, 7.55), (-39.3, 7.6), (-34.4, 7.6), (-29.4, 7.94), (-24.3, 8.27), (-19.4, 8.21), (-14.3, 8.05), (-9.3, 7.77), (-4.3, 7.05), (0.7, 6.33), (5.7, 5.61), (10.7, 4.99), (15.7, 4.5), (20.7, 4.16), (25.7, 3.94), (30.6, 4.11), (35.7, 4.44), (40.6, 4.88), (45.6, 5.22), (50.6, 5.88), (55.6, 6.38), (60.7, 6.49), (65.7, 6.72), (70.7, 6.83), (75.7, 6.72), (80.7, 6.44), (85.7, 6.27), (90.7, 5.99), (95.7, 5.66), (100.7, 5.44), (105.7, 5.33), (110.7, 5.33), (115.7, 5.44), (120.7, 5.44), (125.7, 5.66), (130.6, 5.66), (135.7, 5.72)],
            boluses: [(-262.6, 0.5), (-142.9, 1), (-66.0, 2), (-63.8, 3.5), (-20.1, 1), (57.8, 0.5)],
            meals: [(-47, 80)]
        )
        #expect(fixture.error(calibrated) < fixture.error(before))
    }
}
