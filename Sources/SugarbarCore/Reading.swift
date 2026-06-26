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

public func formatMmolPerL(_ value: Double) -> String {
    String(format: "%.1f", value)
}
