import Foundation

/// Keeps each bucket's lowest and highest Reading, so thinning never hides a low or a high.
public func downsample(_ readings: [Reading], maxPoints: Int) -> [Reading] {
    guard readings.count > maxPoints, maxPoints >= 2, let first = readings.first, let last = readings.last else {
        return readings
    }
    let bucketCount = maxPoints / 2
    let span = last.timestamp.timeIntervalSince(first.timestamp)
    guard span > 0 else { return [first, last] }
    var buckets: [[Reading]] = Array(repeating: [], count: bucketCount)
    for reading in readings {
        let offset = reading.timestamp.timeIntervalSince(first.timestamp) / span
        buckets[min(bucketCount - 1, Int(offset * Double(bucketCount)))].append(reading)
    }
    return buckets.flatMap { bucket -> [Reading] in
        guard let low = bucket.min(by: { $0.value < $1.value }),
              let high = bucket.max(by: { $0.value < $1.value })
        else { return [] }
        if low.timestamp == high.timestamp { return [low] }
        return low.timestamp < high.timestamp ? [low, high] : [high, low]
    }
}

public struct GlucoseEnvelope: Equatable, Sendable {
    public let start: Date
    public let end: Date
    public let low: Double
    public let high: Double
    public let mean: Double

    public var middle: Date { start.addingTimeInterval(end.timeIntervalSince(start) / 2) }
}

/// Split into runs at empty slices so a chart leaves the sensor's gaps empty.
public func glucoseEnvelope(_ readings: [Reading], over interval: ClosedRange<Date>, slices: Int) -> [[GlucoseEnvelope]] {
    let span = interval.upperBound.timeIntervalSince(interval.lowerBound)
    guard slices > 0, span > 0 else { return [] }
    let width = span / Double(slices)
    var groups: [Int: [Double]] = [:]
    for reading in readings where interval.contains(reading.timestamp) {
        let index = min(slices - 1, Int(reading.timestamp.timeIntervalSince(interval.lowerBound) / width))
        groups[index, default: []].append(reading.value)
    }
    var runs: [[GlucoseEnvelope]] = []
    var previous: Int?
    for index in groups.keys.sorted() {
        let values = groups[index]!
        let slice = GlucoseEnvelope(
            start: interval.lowerBound.addingTimeInterval(Double(index) * width),
            end: interval.lowerBound.addingTimeInterval(Double(index + 1) * width),
            low: values.min()!,
            high: values.max()!,
            mean: values.reduce(0, +) / Double(values.count)
        )
        if let previous, previous == index - 1 { runs[runs.count - 1].append(slice) } else { runs.append([slice]) }
        previous = index
    }
    return runs
}

/// So a chart does not draw a line across time the sensor was off.
public func splitAtGaps(_ readings: [Reading], gap: TimeInterval) -> [[Reading]] {
    var segments: [[Reading]] = []
    for reading in readings {
        if let previous = segments.last?.last, reading.timestamp.timeIntervalSince(previous.timestamp) <= gap {
            segments[segments.count - 1].append(reading)
        } else {
            segments.append([reading])
        }
    }
    return segments
}

public extension HistoryWindow {
    /// How far apart Dose and Meal markers are pooled; nil draws each one.
    var markerBucket: TimeInterval? {
        switch self {
        case .fourHours, .twelveHours, .day: nil
        case .threeDays: 6 * 3600
        case .week, .twoWeeks, .thirtyDays: 86400
        case .ninetyDays: 7 * 86400
        }
    }
}

func markerBucketStart(_ date: Date, bucket: TimeInterval, calendar: Calendar) -> Date {
    let anchor = calendar.startOfDay(for: bucket > 86400 ? Date(timeIntervalSinceReferenceDate: 0) : date)
    let elapsed = date.timeIntervalSince(anchor)
    return anchor.addingTimeInterval(floor(elapsed / bucket) * bucket)
}

/// Placed mid-bucket but clamped to its Doses, so a marker never lands in the future.
public func aggregateDoses(_ doses: [InsulinDose], bucket: TimeInterval, calendar: Calendar = .current) -> [InsulinDose] {
    let groups = Dictionary(grouping: doses) { DoseBucketKey(kind: $0.kind, start: markerBucketStart($0.timestamp, bucket: bucket, calendar: calendar)) }
    return groups.map { key, members in
        InsulinDose(
            kind: key.kind,
            units: members.reduce(0) { $0 + $1.units },
            timestamp: markerTimestamp(start: key.start, bucket: bucket, members: members.map(\.timestamp)),
            insulinName: nil,
            deviceName: nil
        )
    }
    .sorted { $0.timestamp < $1.timestamp }
}

public func aggregateMeals(_ meals: [Meal], bucket: TimeInterval, calendar: Calendar = .current) -> [Meal] {
    let groups = Dictionary(grouping: meals) { markerBucketStart($0.timestamp, bucket: bucket, calendar: calendar) }
    return groups.map { start, members in
        let sorted = members.sorted { $0.timestamp < $1.timestamp }
        return Meal(
            id: sorted[0].id,
            timestamp: markerTimestamp(start: start, bucket: bucket, members: sorted.map(\.timestamp)),
            carbsGrams: carbTotal(sorted),
            summary: sorted.count == 1 ? sorted[0].summary : "\(sorted.count) meals"
        )
    }
    .sorted { $0.timestamp < $1.timestamp }
}

private struct DoseBucketKey: Hashable {
    let kind: InsulinKind
    let start: Date
}

private func markerTimestamp(start: Date, bucket: TimeInterval, members: [Date]) -> Date {
    let middle = start.addingTimeInterval(bucket / 2)
    guard let first = members.min(), let last = members.max() else { return middle }
    return min(max(middle, first), last)
}
