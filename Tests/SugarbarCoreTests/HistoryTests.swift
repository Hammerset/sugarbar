import Foundation
import Testing

@testable import SugarbarCore

@Suite struct HistoryWindowTests {
    @Test(arguments: [
        (HistoryWindow.fourHours, 4),
        (HistoryWindow.eightHours, 8),
        (HistoryWindow.twelveHours, 12),
    ])
    func exposesHours(window: HistoryWindow, expected: Int) {
        #expect(window.hours == expected)
    }

    @Test func defaultsToFourHours() {
        #expect(HistoryWindow.allCases.first == .fourHours)
    }
}

@Suite struct ReadingsWithinWindowTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func reading(hoursAgo: Double) -> Reading {
        Reading(value: 5.5, timestamp: now.addingTimeInterval(-hoursAgo * 3600), trend: .stable)
    }

    @Test func keepsReadingsInsideTheWindow() {
        let history = [reading(hoursAgo: 1), reading(hoursAgo: 3), reading(hoursAgo: 6)]
        let result = readings(history, within: .fourHours, of: now)
        #expect(result.count == 2)
    }

    @Test func includesReadingsExactlyOnTheBoundary() {
        let history = [reading(hoursAgo: 4)]
        #expect(readings(history, within: .fourHours, of: now).count == 1)
    }

    @Test func widerWindowKeepsMore() {
        let history = [reading(hoursAgo: 1), reading(hoursAgo: 6), reading(hoursAgo: 10)]
        #expect(readings(history, within: .eightHours, of: now).count == 2)
        #expect(readings(history, within: .twelveHours, of: now).count == 3)
    }
}

@Suite struct MergeReadingsTests {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    private func reading(minutesAgo: Double, value: Double = 5.5, trend: Trend = .notDetermined) -> Reading {
        Reading(value: value, timestamp: base.addingTimeInterval(-minutesAgo * 60), trend: trend)
    }

    @Test func appendsLatestAndSortsAscending() {
        let history = [reading(minutesAgo: 30), reading(minutesAgo: 15)]
        let latest = reading(minutesAgo: 0, trend: .rising)
        let merged = mergeReadings(history: history, latest: latest)
        #expect(merged.count == 3)
        #expect(merged.map(\.timestamp) == merged.map(\.timestamp).sorted())
        #expect(merged.last == latest)
    }

    @Test func dedupesLatestAgainstMatchingHistoryPoint() {
        let stale = reading(minutesAgo: 0, value: 4.0, trend: .notDetermined)
        let latest = reading(minutesAgo: 0, value: 4.0, trend: .rising)
        let merged = mergeReadings(history: [stale], latest: latest)
        #expect(merged.count == 1)
        #expect(merged.first?.trend == .rising)
    }
}
