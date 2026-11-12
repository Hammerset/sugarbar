import Foundation
import Testing

@testable import SugarbarCore

@Suite struct HistoryWindowTests {
    @Test func labelsHoursUpToADayThenDays() {
        #expect(HistoryWindow.allCases.map(\.label) == ["4h", "12h", "24h", "3d", "7d", "14d", "30d", "90d"])
    }

    @Test func defaultsToFourHours() {
        #expect(HistoryWindow.allCases.first == .fourHours)
    }
}

@Suite struct NearestReadingTests {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    private func reading(minutesAgo: Double, value: Double) -> Reading {
        Reading(value: value, timestamp: base.addingTimeInterval(-minutesAgo * 60), trend: .stable)
    }

    @Test func returnsNilForEmptySeries() {
        #expect(nearestReading(to: base, in: []) == nil)
    }

    @Test func snapsToTheClosestReadingInTime() {
        let series = [reading(minutesAgo: 30, value: 4.0), reading(minutesAgo: 10, value: 6.0)]
        let target = base.addingTimeInterval(-12 * 60)
        #expect(nearestReading(to: target, in: series)?.value == 6.0)
    }

    @Test func snapsToEarlierReadingWhenCursorIsBeforeAll() {
        let series = [reading(minutesAgo: 30, value: 4.0), reading(minutesAgo: 10, value: 6.0)]
        let target = base.addingTimeInterval(-60 * 60)
        #expect(nearestReading(to: target, in: series)?.value == 4.0)
    }
}
