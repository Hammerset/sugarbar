public struct Thresholds: Equatable, Sendable {
    public let urgentLow: Double
    public let low: Double
    public let high: Double
    public let urgentHigh: Double

    public init(urgentLow: Double, low: Double, high: Double, urgentHigh: Double) {
        self.urgentLow = urgentLow
        self.low = low
        self.high = high
        self.urgentHigh = urgentHigh
    }

    public static let standard = Thresholds(urgentLow: 3.0, low: 3.9, high: 10.0, urgentHigh: 13.9)

    public var isValid: Bool {
        urgentLow < low && low < high && high < urgentHigh
    }

    public static func validated(urgentLow: Double, low: Double, high: Double, urgentHigh: Double) -> Thresholds? {
        let thresholds = Thresholds(urgentLow: urgentLow, low: low, high: high, urgentHigh: urgentHigh)
        return thresholds.isValid ? thresholds : nil
    }
}

public enum Band: Equatable, Sendable {
    case urgentLow
    case low
    case inRange
    case high
    case urgentHigh

    public init(mmolPerL value: Double, thresholds: Thresholds = .standard) {
        if value < thresholds.urgentLow {
            self = .urgentLow
        } else if value < thresholds.low {
            self = .low
        } else if value <= thresholds.high {
            self = .inRange
        } else if value <= thresholds.urgentHigh {
            self = .high
        } else {
            self = .urgentHigh
        }
    }
}
