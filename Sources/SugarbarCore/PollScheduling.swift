import Foundation

/// Delay until the next poll, aligned to the sensor's per-cadence reading clock:
/// targets `grace` seconds after the next reading that is still in the future, so a
/// poll lands just after each new minute-value is published. A reading that has gone
/// stale keeps the schedule on the cadence grid rather than collapsing to the floor.
public func nextPollDelay(
    afterReadingAt lastReadingAt: Date,
    now: Date,
    cadence: TimeInterval = 60,
    grace: TimeInterval = 5,
    minimum: TimeInterval = 5
) -> TimeInterval {
    let elapsed = now.timeIntervalSince(lastReadingAt)
    let cyclesPast = max(0, Int((elapsed - grace) / cadence))
    let target = cadence * Double(cyclesPast + 1) + grace
    return max(minimum, target - elapsed)
}

/// Equal-jitter exponential backoff for rate-limit (`429`/`430`) recovery: the delay
/// for failure _n_ is `min(cap, base · multiplier^(n-1))`, then randomised within
/// `[window/2, window]` so retries never fire instantly yet stay decorrelated.
public struct BackoffPolicy: Sendable {
    public let base: TimeInterval
    public let cap: TimeInterval
    public let multiplier: Double

    public init(base: TimeInterval = 30, cap: TimeInterval = 600, multiplier: Double = 2) {
        self.base = base
        self.cap = cap
        self.multiplier = multiplier
    }

    public func delay(forFailureCount n: Int, jitter: Double) -> TimeInterval {
        guard n >= 1 else { return 0 }
        let window = min(cap, base * pow(multiplier, Double(n - 1)))
        let half = window / 2
        return half + min(1, max(0, jitter)) * half
    }

    public func delay(forFailureCount n: Int) -> TimeInterval {
        delay(forFailureCount: n, jitter: .random(in: 0...1))
    }

    public static let standard = BackoffPolicy()
}

public enum PollOutcome: Sendable {
    case success(readingAt: Date)
    case rateLimited
    case transientFailure
}

public struct PollPlanner: Sendable {
    public let cadence: TimeInterval
    public let grace: TimeInterval
    public let minimum: TimeInterval
    public let backoff: BackoffPolicy

    public init(cadence: TimeInterval = 60, grace: TimeInterval = 5, minimum: TimeInterval = 5, backoff: BackoffPolicy = .standard) {
        self.cadence = cadence
        self.grace = grace
        self.minimum = minimum
        self.backoff = backoff
    }

    public static let standard = PollPlanner()
}

/// Maps a completed poll to the delay before the next one: a success realigns to the
/// reading clock; a rate-limit or transient failure backs off by the running failure count.
public func nextDelay(
    after outcome: PollOutcome,
    now: Date,
    consecutiveFailures: Int,
    planner: PollPlanner,
    jitter: Double
) -> TimeInterval {
    switch outcome {
    case let .success(readingAt):
        return nextPollDelay(afterReadingAt: readingAt, now: now,
                             cadence: planner.cadence, grace: planner.grace, minimum: planner.minimum)
    case .rateLimited, .transientFailure:
        return planner.backoff.delay(forFailureCount: max(1, consecutiveFailures), jitter: jitter)
    }
}
