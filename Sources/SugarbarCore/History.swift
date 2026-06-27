import Foundation

public enum HistoryWindow: Int, CaseIterable, Identifiable, Sendable {
    case fourHours = 4
    case eightHours = 8
    case twelveHours = 12

    public var hours: Int { rawValue }
    public var id: Int { rawValue }
}

public func readings(_ readings: [Reading], within window: HistoryWindow, of now: Date) -> [Reading] {
    let cutoff = now.addingTimeInterval(-Double(window.hours) * 3600)
    return readings.filter { $0.timestamp >= cutoff }
}

/// Snaps a hovered date to the closest actual Reading. We never interpolate between
/// Readings — every value shown is one the sensor reported.
public func nearestReading(to date: Date, in readings: [Reading]) -> Reading? {
    readings.min { lhs, rhs in
        abs(lhs.timestamp.timeIntervalSince(date)) < abs(rhs.timestamp.timeIntervalSince(date))
    }
}

public func mergeReadings(history: [Reading], latest: Reading) -> [Reading] {
    var byTimestamp: [Date: Reading] = [:]
    for reading in history { byTimestamp[reading.timestamp] = reading }
    byTimestamp[latest.timestamp] = latest
    return byTimestamp.values.sorted { $0.timestamp < $1.timestamp }
}
