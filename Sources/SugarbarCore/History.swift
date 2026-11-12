import Foundation

public enum HistoryWindow: Int, CaseIterable, Identifiable, Sendable {
    case fourHours = 4
    case twelveHours = 12
    case day = 24
    case threeDays = 72
    case week = 168
    case twoWeeks = 336
    case thirtyDays = 720
    case ninetyDays = 2160

    public var hours: Int { rawValue }
    public var id: Int { rawValue }
    public var duration: TimeInterval { Double(hours) * 3600 }
    public var isMultiDay: Bool { hours > 24 }

    public var label: String {
        hours <= 24 ? "\(hours)h" : "\(hours / 24)d"
    }

    public func interval(endingAt now: Date) -> ClosedRange<Date> {
        now.addingTimeInterval(-duration)...now
    }
}

/// Snaps a hovered date to the closest actual Reading. We never interpolate between
/// Readings — every value shown is one the sensor reported.
public func nearestReading(to date: Date, in readings: [Reading]) -> Reading? {
    readings.min { lhs, rhs in
        abs(lhs.timestamp.timeIntervalSince(date)) < abs(rhs.timestamp.timeIntervalSince(date))
    }
}
