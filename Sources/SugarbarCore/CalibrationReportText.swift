import Foundation

public extension CalibrationReport {
    /// The report as Markdown tables: current vs best per stage, the time-since-Bolus bias, the
    /// morning sensitivity test and quiet drift. "(edge)" marks a best value at the end of the search range.
    var markdown: String {
        var lines: [String] = []
        let days = { (range: ClosedRange<Date>) in Int((range.upperBound.timeIntervalSince(range.lowerBound) / 86400).rounded()) }
        lines.append("Fitted on \(days(fittedRange)) days, held out the last \(days(heldOutRange)) days.")
        if let insulin {
            lines.append("")
            lines.append("### Insulin curve and sensitivity, on correction episodes")
            lines += stageTable(insulin, quantities: [.insulinPeak, .insulinDuration, .insulinSensitivity])
        }
        lines.append("")
        lines.append("### Carb ratio and absorption, on meal episodes")
        if let carbs {
            lines += stageTable(carbs, quantities: [.carbRatio, .normalCarbAbsorption])
        } else {
            lines.append("No meal episodes to fit: too few logged Meals.")
        }
        if let current = bolusAge.keys.first(where: { $0 == insulin?.current }) ?? bolusAge.keys.first {
            lines.append("")
            lines.append("### Held-out bias at 60 min by time since the last Bolus")
            let columns = bolusAge.keys.sorted { $0 == current && $1 != current }
            lines.append("| Since Bolus | " + columns.map { $0 == current ? "Current" : "Proposed" }.joined(separator: " | ") + " |")
            lines.append("|---|" + columns.map { _ in "---|" }.joined())
            for age in BolusAge.allCases {
                let cells = columns.map { therapy -> String in
                    guard let error = bolusAge[therapy]?[age]?[60], error.count > 0 else { return "–" }
                    return String(format: "%+.2f (n=%d)", error.bias, error.count)
                }
                lines.append("| \(age.label) | " + cells.joined(separator: " | ") + " |")
            }
        }
        if let morning {
            lines.append("")
            lines.append("### Separate morning sensitivity (05–11)")
            lines.append("All-day \(formatTherapyNumber(morning.allDay)) vs morning \(formatTherapyNumber(morning.morning)) mmol/L/u, fitted on \(morning.fittedEpisodes) episodes: held-out morning error \(two(morning.allDayScore.meanAbsoluteError)) → \(two(morning.morningScore.meanAbsoluteError)) (\(morning.morningScore.episodes) episodes).")
        }
        lines.append("")
        lines.append("### Drift in quiet episodes (no Bolus or Meal for 5 h)")
        lines.append("Night (00–06): \(drift.night.map { signed(rate: $0) } ?? "–") over \(Int(drift.nightHours.rounded())) h; day: \(drift.day.map { signed(rate: $0) } ?? "–") over \(Int(drift.dayHours.rounded())) h; \(drift.episodes) episodes.")
        lines.append("")
        if let proposal {
            let changes = proposal.changes.map { "\($0.quantity.name) \($0.quantity.format($0.current)) → \($0.quantity.format($0.proposed))" }
            lines.append("**Proposal:** " + changes.joined(separator: ", ") + ". Held-out error \(two(proposal.heldOutError)) → \(two(proposal.proposedHeldOutError)) (\(Int((proposal.improvement * 100).rounded()))% better).")
        } else {
            lines.append("**No proposal:** nothing within ±15% beats the current settings on the held-out days by enough, or there are too few episodes.")
        }
        return lines.joined(separator: "\n")
    }
}

private func stageTable(_ stage: CalibrationStage, quantities: [TherapyQuantity]) -> [String] {
    let columns: [(String, TherapySettings)] = [("Current", stage.current), ("Best", stage.best), ("Within ±15%", stage.capped)]
    var lines = ["| | " + columns.map(\.0).joined(separator: " | ") + " |", "|---|---|---|---|"]
    for quantity in quantities {
        lines.append("| \(quantity.name) | " + columns.map { column in
            guard let value = column.1[quantity] else { return "–" }
            return quantity.format(value) + (stage.edges.contains(quantity) && column.0 == "Best" ? " (edge)" : "")
        }.joined(separator: " | ") + " |")
    }
    for (name, scores) in [("Fitted", stage.fitted), ("Held out", stage.heldOut)] {
        lines.append("| \(name) episodes | " + columns.map { scores[$0.1].map { "\($0.episodes)" } ?? "–" }.joined(separator: " | ") + " |")
        for minute in forecastScoreHorizons {
            let cells = columns.map { column -> String in
                guard let error = scores[column.1]?.errors[minute], error.count > 0 else { return "–" }
                return String(format: "±%.2f / %+.2f", error.meanAbsoluteError, error.bias)
            }
            guard cells.contains(where: { $0 != "–" }) else { continue }
            lines.append("| \(name) \(minute) min MAE / bias | " + cells.joined(separator: " | ") + " |")
        }
    }
    return lines
}

private func two(_ value: Double) -> String { String(format: "%.2f", value) }

private func signed(rate: Double) -> String { String(format: "%+.2f mmol/L/h", rate) }
