import SwiftUI
import SugarbarCore

/// The track record behind the one-line accuracy summary: error per horizon, per situation, and how the warnings did.
public struct ForecastAccuracyBreakdown: View {
    let scorecard: ForecastScorecard
    let isReplayed: Bool

    public init(scorecard: ForecastScorecard, isReplayed: Bool) {
        self.scorecard = scorecard
        self.isReplayed = isReplayed
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                GridRow {
                    Text("Ahead")
                    Text("Off by").gridColumnAlignment(.trailing)
                    Text("Tends to")
                }
                .foregroundStyle(.secondary)
                ForEach(forecastScoreHorizons, id: \.self) { minute in
                    let error = scorecard.error(atMinute: minute)
                    if error.count > 0 {
                        GridRow {
                            Text("\(minute) min")
                            Text("±\(formatOneDecimal(error.meanAbsoluteError))").monospacedDigit()
                            Text(biasText(error.bias)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !situations.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("At 60 min").foregroundStyle(.secondary)
                    ForEach(situations, id: \.0) { situation, error in
                        Text("\(situation.label): ±\(formatOneDecimal(error.meanAbsoluteError)), \(biasText(error.bias))")
                    }
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(alertLine("Heading low", scorecard.headingLow))
                Text(alertLine("Falling fast", scorecard.fallingFast))
            }
            Text(sourceLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
    }

    private var situations: [(ForecastSituation, ForecastError)] {
        ForecastSituation.allCases.compactMap { situation in
            guard let error = scorecard.bySituation[situation]?[60], error.count >= 12 else { return nil }
            return (situation, error)
        }
    }

    private var sourceLine: String {
        let count = scorecard.forecastCount.formatted()
        if isReplayed {
            return "\(count) Forecasts replayed from History with your current settings, until this device has logged a day of its own. Off by: the average miss in mmol/L."
        }
        return "From \(count) Forecasts this device made. Off by: the average miss in mmol/L. A Pen Dose not yet synced counts against the Forecast."
    }

    private func biasText(_ bias: Double) -> String {
        if abs(bias) < 0.15 { return "on target" }
        return bias > 0 ? "reads \(formatOneDecimal(bias)) high" : "reads \(formatOneDecimal(-bias)) low"
    }

    private func alertLine(_ name: String, _ score: AlertScore) -> String {
        guard score.warnings + score.misses > 0 else { return "\(name): no warnings or events" }
        var line = "\(name): \(score.hits) of \(score.warnings) warnings right"
        if score.misses > 0 { line += ", \(score.misses) missed" }
        if let lead = score.meanLeadTime { line += ", about \(Int((lead / 60).rounded())) min ahead" }
        return line
    }
}
