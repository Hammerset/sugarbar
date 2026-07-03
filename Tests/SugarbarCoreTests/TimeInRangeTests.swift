import Foundation
import Testing

@testable import SugarbarCore

@Suite struct TimeInRangeTests {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    private func reading(value: Double, minutesAgo: Double = 0) -> Reading {
        Reading(value: value, timestamp: base.addingTimeInterval(-minutesAgo * 60), trend: .stable)
    }

    @Test func returnsNilForEmptyReadings() {
        #expect(timeInRange([]) == nil)
    }

    @Test func allInRangeReadingsScoreFullyInRange() {
        let readings = [reading(value: 5.0), reading(value: 6.0), reading(value: 7.0)]
        let summary = timeInRange(readings)
        #expect(summary?.inRangePercent == 100)
        #expect(summary?.lowPercent == 0)
        #expect(summary?.highPercent == 0)
    }

    @Test func rollsUrgentSubLevelsIntoTheirParentBucket() {
        let readings = [
            reading(value: 2.5), // urgentLow -> low bucket
            reading(value: 3.5), // low
            reading(value: 5.0), // inRange
            reading(value: 11.0), // high
            reading(value: 16.0), // urgentHigh -> high bucket
        ]
        let summary = timeInRange(readings)
        #expect(summary?.lowPercent == 40)
        #expect(summary?.inRangePercent == 20)
        #expect(summary?.highPercent == 40)
    }

    @Test func honoursCustomThresholds() {
        let tighter = Thresholds(urgentLow: 4.0, low: 4.5, high: 8.0, urgentHigh: 12.0)
        let readings = [reading(value: 4.2), reading(value: 6.0), reading(value: 9.0), reading(value: 6.0)]
        let summary = timeInRange(readings, thresholds: tighter)
        #expect(summary?.lowPercent == 25)
        #expect(summary?.inRangePercent == 50)
        #expect(summary?.highPercent == 25)
    }
}
