import Foundation

/// A Libre 3 sensor delivers no readings for the first 60 minutes after activation.
public let warmUpDuration: TimeInterval = 60 * 60

/// Seconds left in the warm-up window, or `nil` once it has elapsed (or there is no
/// known activation). A future activation (clock skew) caps at the full window rather
/// than reporting more than a fresh sensor would.
public func warmUpRemaining(
    activatedAt: Date?,
    now: Date,
    duration: TimeInterval = warmUpDuration
) -> TimeInterval? {
    guard let activatedAt else { return nil }
    let remaining = min(duration, duration - now.timeIntervalSince(activatedAt))
    return remaining > 0 ? remaining : nil
}
