import Foundation
import Testing

@testable import SugarbarCore

@Suite struct SensorStateTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func reportsRemainingTimeDuringWarmUp() {
        let activated = now.addingTimeInterval(-10 * 60)
        #expect(warmUpRemaining(activatedAt: activated, now: now) == TimeInterval(50 * 60))
    }

    @Test func notWarmingUpOnceWindowElapsed() {
        let activated = now.addingTimeInterval(-warmUpDuration)
        #expect(warmUpRemaining(activatedAt: activated, now: now) == nil)
        #expect(warmUpRemaining(activatedAt: now.addingTimeInterval(-3 * 3600), now: now) == nil)
    }

    @Test func notWarmingUpWithoutActivation() {
        #expect(warmUpRemaining(activatedAt: nil, now: now) == nil)
    }

    @Test func ignoresFutureActivationClockSkew() {
        #expect(warmUpRemaining(activatedAt: now.addingTimeInterval(120), now: now) == warmUpDuration)
    }
}
