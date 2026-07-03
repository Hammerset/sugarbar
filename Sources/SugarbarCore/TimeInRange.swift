public struct TimeInRangeSummary: Equatable, Sendable {
    public let inRangePercent: Double
    public let lowPercent: Double
    public let highPercent: Double

    public init(inRangePercent: Double, lowPercent: Double, highPercent: Double) {
        self.inRangePercent = inRangePercent
        self.lowPercent = lowPercent
        self.highPercent = highPercent
    }
}

public func timeInRange(_ readings: [Reading], thresholds: Thresholds = .standard) -> TimeInRangeSummary? {
    guard !readings.isEmpty else { return nil }
    var inRange = 0
    var low = 0
    var high = 0
    for reading in readings {
        switch Band(mmolPerL: reading.value, thresholds: thresholds) {
        case .inRange: inRange += 1
        case .low, .urgentLow: low += 1
        case .high, .urgentHigh: high += 1
        }
    }
    let total = Double(readings.count)
    return TimeInRangeSummary(
        inRangePercent: Double(inRange) / total * 100,
        lowPercent: Double(low) / total * 100,
        highPercent: Double(high) / total * 100
    )
}
