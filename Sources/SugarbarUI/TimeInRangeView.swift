import SwiftUI
import SugarbarCore

public struct TimeInRangeView: View {
    private let summary: TimeInRangeSummary?

    public init(summary: TimeInRangeSummary?) {
        self.summary = summary
    }

    public var body: some View {
        if let summary {
            VStack(spacing: 6) {
                GeometryReader { proxy in
                    HStack(spacing: 0) {
                        ForEach(Band.allCases, id: \.self) { band in
                            Rectangle()
                                .fill(band.tint)
                                .frame(width: proxy.size.width * summary.percent(band) / 100)
                        }
                    }
                }
                .frame(height: 8)
                .clipShape(Capsule())
                HStack(spacing: 0) {
                    ForEach(Band.allCases, id: \.self) { band in
                        VStack(spacing: 1) {
                            Text("\(Int(summary.percent(band).rounded()))%")
                                .font(.callout.bold().monospacedDigit())
                                .foregroundStyle(band.tint)
                            Text(band.timeInRangeLabel)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        } else {
            Text("Not enough data yet")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private extension Band {
    var timeInRangeLabel: String {
        switch self {
        case .urgentLow: "Very low"
        case .low: "Low"
        case .inRange: "In range"
        case .high: "High"
        case .urgentHigh: "Very high"
        }
    }
}
