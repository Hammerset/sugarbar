import Foundation
import Testing

@testable import SugarbarCore

@Suite struct BarContentScheduleTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func reading(mgPerDl: Double, ageSeconds: TimeInterval, trend: Trend = .stable) -> Reading {
        Reading(
            value: mmolPerL(fromMgPerDl: mgPerDl),
            timestamp: now.addingTimeInterval(-ageSeconds),
            trend: trend
        )
    }

    @Test func freshReadingSchedulesTransitionToStale() {
        let r = reading(mgPerDl: 100, ageSeconds: 60)
        let schedule = barContentSchedule(latest: r, sensorActivation: nil, now: now)

        #expect(schedule.map(\.date) == [now, r.timestamp.addingTimeInterval(stalenessThreshold + 1)])
        #expect(schedule.map(\.content) == [
            .live(value: r.value, band: .inRange, trend: .stable, outOfRange: nil),
            .stale(value: r.value, band: .inRange, outOfRange: nil),
        ])
    }

    @Test func alreadyStaleReadingHasNoFurtherTransition() {
        let r = reading(mgPerDl: 100, ageSeconds: 600)
        let schedule = barContentSchedule(latest: r, sensorActivation: nil, now: now)

        #expect(schedule.map(\.date) == [now])
        #expect(schedule.map(\.content) == [.stale(value: r.value, band: .inRange, outOfRange: nil)])
    }

    @Test func warmUpWithNoReadingSchedulesTransitionToEmpty() {
        let activated = now.addingTimeInterval(-15 * 60)
        let schedule = barContentSchedule(latest: nil, sensorActivation: activated, now: now)

        #expect(schedule.map(\.date) == [now, activated.addingTimeInterval(warmUpDuration)])
        #expect(schedule.map(\.content) == [.warmingUp(remaining: 45 * 60), .empty])
    }

    @Test func warmUpOverStaleReadingSchedulesTransitionToStale() {
        let r = reading(mgPerDl: 100, ageSeconds: 600)
        let activated = now.addingTimeInterval(-15 * 60)
        let schedule = barContentSchedule(latest: r, sensorActivation: activated, now: now)

        #expect(schedule.map(\.date) == [now, activated.addingTimeInterval(warmUpDuration)])
        #expect(schedule.map(\.content) == [
            .warmingUp(remaining: 45 * 60),
            .stale(value: r.value, band: .inRange, outOfRange: nil),
        ])
    }

    @Test func emptyStateHasSingleEntry() {
        let schedule = barContentSchedule(latest: nil, sensorActivation: nil, now: now)

        #expect(schedule.map(\.date) == [now])
        #expect(schedule.map(\.content) == [.empty])
    }

    @Test func elapsedWarmUpWithNoOtherSignalIsNotScheduledAsAFutureTransition() {
        let activated = now.addingTimeInterval(-2 * 3600)
        let schedule = barContentSchedule(latest: nil, sensorActivation: activated, now: now)

        #expect(schedule.map(\.date) == [now])
        #expect(schedule.map(\.content) == [.empty])
    }
}
