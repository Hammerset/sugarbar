import Foundation
import Testing

@testable import SugarbarCore

@Suite struct ChartDensityTests {
    private let start = Date(timeIntervalSince1970: 1_791_800_000)

    private func series(minutes: Int, every step: Int = 1, value: (Int) -> Double = { _ in 6 }) -> [Reading] {
        stride(from: 0, to: minutes, by: step).map {
            Reading(value: value($0), timestamp: start.addingTimeInterval(Double($0) * 60), trend: .stable)
        }
    }

    @Test func downsamplingKeepsEachBucketsExtremesInTimeOrder() {
        let readings = series(minutes: 10_000) { $0 == 1234 ? 2.2 : ($0 == 7777 ? 19.5 : 6 + Double($0 % 7) / 10) }
        let thinned = downsample(readings, maxPoints: 200)

        #expect(thinned.count <= 200)
        #expect(thinned.contains { $0.value == 2.2 })
        #expect(thinned.contains { $0.value == 19.5 })
        #expect(zip(thinned, thinned.dropFirst()).allSatisfy { $0.timestamp < $1.timestamp })
        #expect(downsample(Array(readings.prefix(150)), maxPoints: 200).count == 150)
    }

    @Test func splitsTheLineWhereTheSensorWasOff() {
        let readings = series(minutes: 60, every: 5) + series(minutes: 300, every: 5).filter { $0.timestamp > start.addingTimeInterval(200 * 60) }
        let segments = splitAtGaps(readings, gap: 30 * 60)
        #expect(segments.map(\.count) == [12, 19])
    }

    @Test func envelopeSummarisesSlicesAndBreaksAtEmptyOnes() {
        // Four one-hour slices; the third has no Readings.
        let readings = series(minutes: 240, every: 5) { $0 / 60 == 2 ? 0 : Double($0 % 60) / 10 + 4 }
            .filter { $0.value > 0 }
        let runs = glucoseEnvelope(readings, over: start...start.addingTimeInterval(4 * 3600), slices: 4)

        #expect(runs.map(\.count) == [2, 1])
        #expect(runs[0][0].low == 4.0)
        #expect(runs[0][0].high == 9.5)
        #expect(abs(runs[0][0].mean - 6.75) < 0.0001)
        #expect(runs[1][0].start == start.addingTimeInterval(3 * 3600))
    }

    @Test func poolsDosesAndMealsPerLocalDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Oslo")!
        // 1_791_800_000 is 12 Oct 2026 12:13 in Oslo.
        let doses = [
            InsulinDose(kind: .bolus, units: 4, timestamp: start, insulinName: nil, deviceName: "pen"),
            InsulinDose(kind: .bolus, units: 2.5, timestamp: start.addingTimeInterval(3 * 3600), insulinName: nil, deviceName: "pen"),
            InsulinDose(kind: .basal, units: 10, timestamp: start.addingTimeInterval(4 * 3600), insulinName: nil, deviceName: nil),
            InsulinDose(kind: .bolus, units: 3, timestamp: start.addingTimeInterval(14 * 3600), insulinName: nil, deviceName: "pen"),
        ]
        let pooled = aggregateDoses(doses, bucket: 86400, calendar: calendar)
        #expect(pooled.map(\.units) == [6.5, 10, 3])
        #expect(pooled[0].timestamp == start)

        let meals = [
            Meal(timestamp: start, carbsGrams: 40, summary: "Lunch"),
            Meal(timestamp: start.addingTimeInterval(6 * 3600), carbsGrams: 60, summary: "Dinner"),
        ]
        let pooledMeals = aggregateMeals(meals, bucket: 86400, calendar: calendar)
        #expect(pooledMeals.map(\.carbsGrams) == [100])
        #expect(pooledMeals.map(\.summary) == ["2 meals"])
    }
}
