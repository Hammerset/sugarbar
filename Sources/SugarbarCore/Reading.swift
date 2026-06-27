import Foundation

public struct Reading: Equatable, Sendable {
    public let value: Double
    public let timestamp: Date
    public let trend: Trend

    public init(value: Double, timestamp: Date, trend: Trend) {
        self.value = value
        self.timestamp = timestamp
        self.trend = trend
    }
}

private let mgPerDlPerMmolPerL = 18.0182

public func mmolPerL(fromMgPerDl mgPerDl: Double) -> Double {
    mgPerDl / mgPerDlPerMmolPerL
}

/// The sensor only reports within 40–500 mg/dL; outside that it clamps to the bound
/// and the official app shows LO/HI. We infer the same from the value alone rather
/// than trusting the API's undocumented isLow/isHigh flags.
public enum OutOfRange: Equatable, Sendable {
    case low
    case high

    public var label: String {
        switch self {
        case .low: "LO"
        case .high: "HI"
        }
    }
}

public extension Reading {
    var outOfRange: OutOfRange? {
        if value <= mmolPerL(fromMgPerDl: 40) { return .low }
        if value >= mmolPerL(fromMgPerDl: 500) { return .high }
        return nil
    }
}

public func formatMmolPerL(_ value: Double) -> String {
    String(format: "%.1f", value)
}
