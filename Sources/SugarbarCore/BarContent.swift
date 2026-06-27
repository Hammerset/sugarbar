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
