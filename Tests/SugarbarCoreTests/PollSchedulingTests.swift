import Foundation
import Testing

@testable import SugarbarCore

@Suite struct NextPollDelayTests {
    private let epoch = Date(timeIntervalSince1970: 1_000_000)

    private func delay(elapsed: TimeInterval, minimum: TimeInterval = 5) -> TimeInterval {
        nextPollDelay(
            afterReadingAt: epoch,
            now: epoch.addingTimeInterval(elapsed),
            cadence: 60,
            grace: 5,
            minimum: minimum
        )
    }

    @Test func aimsAtNextReadingPlusGraceRightAfterAReading() {
        #expect(delay(elapsed: 0) == 65)
    }

    @Test func keepsTheMinuteCadenceOnceAligned() {
        #expect(delay(elapsed: 5) == 60)
    }

    @Test func shrinksAsTheNextSlotApproaches() {
        #expect(delay(elapsed: 55) == 10)
    }

    @Test func jumpsToTheFollowingSlotOncePastOne() {
        #expect(delay(elapsed: 65) == 60)
        #expect(delay(elapsed: 70) == 55)
    }

    @Test func staysOnTheGridWhenDataStalls() {
        // A reading 3+ cadences old still schedules within one cadence, never instantly.
        let d = delay(elapsed: 185)
        #expect(d > 0 && d <= 60)
    }

    @Test func neverSchedulesBelowTheMinimumFloor() {
        #expect(delay(elapsed: 64, minimum: 5) == 5)
    }
}

@Suite struct BackoffPolicyTests {
    private let policy = BackoffPolicy(base: 30, cap: 600, multiplier: 2)

    @Test func growsExponentiallyAtFullJitter() {
        #expect(policy.delay(forFailureCount: 1, jitter: 1) == 30)
        #expect(policy.delay(forFailureCount: 2, jitter: 1) == 60)
        #expect(policy.delay(forFailureCount: 3, jitter: 1) == 120)
    }

    @Test func keepsAFloorOfHalfTheWindowAtZeroJitter() {
        #expect(policy.delay(forFailureCount: 1, jitter: 0) == 15)
        #expect(policy.delay(forFailureCount: 2, jitter: 0) == 30)
    }

    @Test func interpolatesBetweenFloorAndWindowAcrossJitter() {
        // failureCount 2 → window 60, equal-jitter band [30, 60]
        #expect(policy.delay(forFailureCount: 2, jitter: 0.5) == 45)
    }

    @Test func respectsTheCap() {
        #expect(policy.delay(forFailureCount: 99, jitter: 1) == 600)
        #expect(policy.delay(forFailureCount: 99, jitter: 0) == 300)
    }

    @Test func clampsOutOfRangeJitter() {
        #expect(policy.delay(forFailureCount: 1, jitter: -3) == 15)
        #expect(policy.delay(forFailureCount: 1, jitter: 4) == 30)
    }

    @Test func returnsZeroForNonPositiveFailureCount() {
        #expect(policy.delay(forFailureCount: 0, jitter: 1) == 0)
    }
}

@Suite struct NextDelayTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let planner = PollPlanner.standard

    @Test func successSchedulesAlignedToTheReading() {
        let readingAt = now.addingTimeInterval(-5)
        let delay = nextDelay(
            after: .success(readingAt: readingAt),
            now: now,
            consecutiveFailures: 0,
            planner: planner,
            jitter: 1
        )
        #expect(delay == nextPollDelay(afterReadingAt: readingAt, now: now,
                                       cadence: planner.cadence, grace: planner.grace, minimum: planner.minimum))
        #expect(delay == 60)
    }

    @Test func rateLimitBacksOffByFailureCount() {
        #expect(nextDelay(after: .rateLimited, now: now, consecutiveFailures: 1, planner: planner, jitter: 1) == 30)
        #expect(nextDelay(after: .rateLimited, now: now, consecutiveFailures: 2, planner: planner, jitter: 1) == 60)
    }

    @Test func transientFailureAlsoBacksOff() {
        #expect(nextDelay(after: .transientFailure, now: now, consecutiveFailures: 3, planner: planner, jitter: 0) == 60)
    }
}
