import Foundation
import Testing

@testable import SugarbarCore

@Suite struct BarContentTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func reading(mgPerDl: Double, ageSeconds: TimeInterval, trend: Trend = .stable) -> Reading {
        Reading(
            value: mmolPerL(fromMgPerDl: mgPerDl),
            timestamp: now.addingTimeInterval(-ageSeconds),
            trend: trend
        )
    }

    @Test func freshInRangeReadingIsLive() {
        let r = reading(mgPerDl: 100, ageSeconds: 60, trend: .rising)
        let content = barContent(latest: r, sensorActivation: nil, now: now)
        #expect(content == .live(value: r.value, band: .inRange, trend: .rising, outOfRange: nil))
    }

    @Test func freshLowOutOfRangeReadingIsLiveLO() {
        let r = reading(mgPerDl: 40, ageSeconds: 30)
        let content = barContent(latest: r, sensorActivation: nil, now: now)
        #expect(content == .live(value: r.value, band: .urgentLow, trend: .stable, outOfRange: .low))
    }

    @Test func freshHighOutOfRangeReadingIsLiveHI() {
        let r = reading(mgPerDl: 500, ageSeconds: 30)
        let content = barContent(latest: r, sensorActivation: nil, now: now)
        #expect(content == .live(value: r.value, band: .urgentHigh, trend: .stable, outOfRange: .high))
    }

    /// The core Phase-6 invariant: a stale reading is never presented as live, even
    /// when its value sits comfortably in the green band.
    @Test func staleInRangeReadingIsNeverLive() {
        let r = reading(mgPerDl: 100, ageSeconds: 600, trend: .rising)
        let content = barContent(latest: r, sensorActivation: nil, now: now)
        #expect(content == .stale(value: r.value, band: .inRange, outOfRange: nil))
    }

    @Test func warmUpWinsWhenNoFreshReading() {
        let activated = now.addingTimeInterval(-15 * 60)
        let content = barContent(latest: nil, sensorActivation: activated, now: now)
        #expect(content == .warmingUp(remaining: 45 * 60))
    }

    @Test func warmUpWinsOverAStaleReadingFromAnOldSensor() {
        let stale = reading(mgPerDl: 100, ageSeconds: 600)
        let activated = now.addingTimeInterval(-15 * 60)
        let content = barContent(latest: stale, sensorActivation: activated, now: now)
        #expect(content == .warmingUp(remaining: 45 * 60))
    }

    @Test func staleReadingShownOnceWarmUpElapsed() {
        let stale = reading(mgPerDl: 100, ageSeconds: 600)
        let activated = now.addingTimeInterval(-2 * 3600)
        let content = barContent(latest: stale, sensorActivation: activated, now: now)
        #expect(content == .stale(value: stale.value, band: .inRange, outOfRange: nil))
    }

    @Test func emptyWhenNothingKnown() {
        #expect(barContent(latest: nil, sensorActivation: nil, now: now) == .empty)
    }
}
