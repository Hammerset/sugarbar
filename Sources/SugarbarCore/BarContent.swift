import Foundation

/// What the menu bar should render right now. The single source of truth that keeps
/// every non-happy state from masquerading as a live, in-range reading: only `.live`
/// is ever drawn in its band colour — `.stale` is greyed, `.warmingUp`/`.empty` show
/// no number at all.
public enum BarContent: Equatable, Sendable {
    case empty
    case warmingUp(remaining: TimeInterval)
    case live(value: Double, band: Band, trend: Trend, outOfRange: OutOfRange?)
    case stale(value: Double, band: Band, outOfRange: OutOfRange?)
}

/// Resolves the bar presentation from the latest reading and sensor activation.
/// Priority: a fresh reading wins; otherwise an unfinished warm-up; otherwise the
/// last reading greyed as stale; otherwise nothing.
public func barContent(
    latest: Reading?,
    sensorActivation: Date?,
    now: Date,
    thresholds: Thresholds = .standard,
    staleAfter: TimeInterval = stalenessThreshold,
    warmUp: TimeInterval = warmUpDuration
) -> BarContent {
    if let latest, !latest.isStale(at: now, threshold: staleAfter) {
        let band = Band(mmolPerL: latest.value, thresholds: thresholds)
        return .live(value: latest.value, band: band, trend: latest.trend, outOfRange: latest.outOfRange)
    }
    if let remaining = warmUpRemaining(activatedAt: sensorActivation, now: now, duration: warmUp) {
        return .warmingUp(remaining: remaining)
    }
    if let latest {
        let band = Band(mmolPerL: latest.value, thresholds: thresholds)
        return .stale(value: latest.value, band: band, outOfRange: latest.outOfRange)
    }
    return .empty
}

/// A `BarContent` that holds from `date` onward, until the schedule's next entry.
public struct ScheduledBarContent: Equatable, Sendable {
    public let date: Date
    public let content: BarContent

    public init(date: Date, content: BarContent) {
        self.date = date
        self.content = content
    }
}

/// Pre-bakes every future `barContent` change from `now` onward, so a display that
/// can't re-poll (a WidgetKit timeline) can still age from live to stale, or from
/// warm-up to whatever follows, entirely on its own.
public func barContentSchedule(
    latest: Reading?,
    sensorActivation: Date?,
    now: Date,
    thresholds: Thresholds = .standard,
    staleAfter: TimeInterval = stalenessThreshold,
    warmUp: TimeInterval = warmUpDuration
) -> [ScheduledBarContent] {
    var candidateDates = [now]
    if let latest {
        // `isStale` is a strict `>`, so the reading is still live at the exact
        // threshold instant — nudge one second past it to land on the transition.
        let staleAt = latest.timestamp.addingTimeInterval(staleAfter + 1)
        if staleAt > now { candidateDates.append(staleAt) }
    }
    if let sensorActivation {
        let warmUpEndsAt = sensorActivation.addingTimeInterval(warmUp)
        if warmUpEndsAt > now { candidateDates.append(warmUpEndsAt) }
    }
    candidateDates.sort()

    var schedule: [ScheduledBarContent] = []
    for date in candidateDates {
        let content = barContent(
            latest: latest,
            sensorActivation: sensorActivation,
            now: date,
            thresholds: thresholds,
            staleAfter: staleAfter,
            warmUp: warmUp
        )
        if schedule.last?.content != content {
            schedule.append(ScheduledBarContent(date: date, content: content))
        }
    }
    return schedule
}
