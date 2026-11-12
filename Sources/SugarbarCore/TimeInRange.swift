import Foundation

public struct TimeInRangeSummary: Equatable, Sendable {
    public let percentByBand: [Band: Double]

    public init(percentByBand: [Band: Double]) {
        self.percentByBand = percentByBand
    }

    public func percent(_ band: Band) -> Double { percentByBand[band] ?? 0 }

    public var inRangePercent: Double { percent(.inRange) }
    public var lowPercent: Double { percent(.urgentLow) + percent(.low) }
    public var highPercent: Double { percent(.high) + percent(.urgentHigh) }
}

/// Live Readings arrive every minute and backfilled ones every five, so each slot counts once.
public let timeInRangeSlot: TimeInterval = 5 * 60

public func timeInRange(_ readings: [Reading], thresholds: Thresholds = .standard) -> TimeInRangeSummary? {
    guard !readings.isEmpty else { return nil }
    let slots = Dictionary(grouping: readings) { Int(floor($0.timestamp.timeIntervalSince1970 / timeInRangeSlot)) }
    var weights: [Band: Double] = [:]
    for slotReadings in slots.values {
        let counts = Dictionary(grouping: slotReadings) { Band(mmolPerL: $0.value, thresholds: thresholds) }
        for (band, members) in counts {
            weights[band, default: 0] += Double(members.count) / Double(slotReadings.count)
        }
    }
    let total = Double(slots.count)
    return TimeInRangeSummary(percentByBand: weights.mapValues { $0 / total * 100 })
}
