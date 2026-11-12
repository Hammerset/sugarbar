import SwiftUI
import SugarbarCore

/// One Suggestion in plain words with Accept and Dismiss.
public struct TherapySuggestionRow: View {
    let suggestion: TherapySuggestion
    let onAccept: () -> Void
    let onDismiss: () -> Void

    public init(suggestion: TherapySuggestion, onAccept: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.suggestion = suggestion
        self.onAccept = onAccept
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(suggestion.text, systemImage: "lightbulb")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Accept", action: onAccept)
                    .buttonStyle(.borderedProminent)
                Button("Dismiss", action: onDismiss)
                    .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
    }
}

/// Per quantity: the working value, what History suggests and the evidence behind it.
public struct TherapyEstimateRows: View {
    let estimate: TherapyEstimate?
    let therapy: TherapySettings
    let isEstimating: Bool
    let onEstimate: () -> Void

    public init(estimate: TherapyEstimate?, therapy: TherapySettings, isEstimating: Bool, onEstimate: @escaping () -> Void) {
        self.estimate = estimate
        self.therapy = therapy
        self.isEstimating = isEstimating
        self.onEstimate = onEstimate
    }

    public static let note = "Learned from clean stretches of your History: a correction Bolus with no food, or a logged Meal with its Bolus, and nothing else for about four hours. Recent days count most. Time-of-day values are shown for reference; the Forecast uses one value."

    public var body: some View {
        ForEach(TherapyQuantity.allCases, id: \.self) { quantity in
            quantityRows(quantity)
        }
        if let skipped = skippedLine {
            Text(skipped).font(.caption).foregroundStyle(.secondary)
        }
        HStack {
            if let estimate {
                Text("Estimated \(estimate.computedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isEstimating {
                ProgressView().controlSize(.small)
            } else {
                Button("Estimate Now", action: onEstimate)
            }
        }
    }

    @ViewBuilder
    private func quantityRows(_ quantity: TherapyQuantity) -> some View {
        let name = quantity == .carbRatio ? "Carb ratio" : "Insulin sensitivity"
        let learned = estimate?.estimate(quantity)
        LabeledContent(name) {
            VStack(alignment: .trailing, spacing: 2) {
                Text("Working: \(therapy[quantity].map { formatTherapyValue($0, quantity) } ?? "not set")")
                Text("Learned: \(learned.map { formatTherapyValue(rounded($0.value), quantity) } ?? "—")")
                    .foregroundStyle(.secondary)
            }
        }
        if let learned {
            Text(evidenceLine(learned))
                .font(.caption)
                .foregroundStyle(.secondary)
            if !learned.byTimeOfDay.isEmpty {
                Text(learned.byTimeOfDay.map { "\($0.timeOfDay.label) \(formatTherapyNumber(rounded($0.value)))" }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            DisclosureGroup("Episodes (\(learned.episodes.count))") {
                ForEach(learned.episodes.prefix(30)) { episode in
                    Text(episodeLine(episode, quantity))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(episode.isOutlier ? .tertiary : .secondary)
                }
            }
            .font(.caption)
        } else {
            Text(missingLine(quantity))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func rounded(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    private func evidenceLine(_ learned: QuantityEstimate) -> String {
        let noun = learned.quantity == .carbRatio ? "meals" : "corrections"
        let unit = learned.quantity == .carbRatio ? "g" : "mmol/L"
        var line = "From \(learned.episodeCount) \(noun) (weight of \(formatTherapyNumber(rounded(learned.effectiveSampleSize))) recent ones), middle half \(formatTherapyNumber(rounded(learned.spread.lowerBound)))–\(formatTherapyNumber(rounded(learned.spread.upperBound))) \(unit), ±\(Int((learned.relativeStandardError * 100).rounded()))%."
        if learned.quantity == .carbRatio, let basis = estimate?.carbRatioBasis {
            switch basis {
            case let .estimatedSensitivity(value): line += " Uses the learned sensitivity \(formatTherapyNumber(rounded(value)))."
            case let .workingSensitivity(value): line += " Assumes your working sensitivity \(formatTherapyNumber(value))."
            }
        }
        if !learned.hasEnoughEvidence { line += " Not enough yet to suggest a change." }
        return line
    }

    private func missingLine(_ quantity: TherapyQuantity) -> String {
        if quantity == .insulinSensitivity {
            return "No clean corrections yet: a Bolus taken above range with no food before or for about four hours after."
        }
        if let unresolved = estimate?.unresolvedMealEpisodes, unresolved > 0 {
            return "\(unresolved) clean meals found, but a meal alone cannot separate the carb ratio from sensitivity. Enter an insulin sensitivity, or let one be learned from corrections, to get a carb ratio."
        }
        return "No clean meals yet: a logged Meal with its Bolus and nothing else eaten or injected for about four hours."
    }

    private var skippedLine: String? {
        guard let rejections = estimate?.rejections, !rejections.isEmpty else { return nil }
        let total = rejections.values.reduce(0, +)
        let reasons = rejections.sorted { $0.value > $1.value }.prefix(3).map { "\($0.value) \($0.key.rawValue)" }
        return "Skipped \(total) stretches: " + reasons.joined(separator: ", ") + (rejections.count > 3 ? ", …" : "") + "."
    }

    private func episodeLine(_ episode: TherapyEpisode, _ quantity: TherapyQuantity) -> String {
        let date = episode.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
        let food = episode.kind == .meal ? "\(formatGrams(episode.carbsGrams)) g, " : ""
        let glucose = "\(formatMmolPerL(episode.startGlucose)) → \(formatMmolPerL(episode.endGlucose))"
        let unit = quantity == .carbRatio ? "g/u" : "mmol/L/u"
        let outlier = episode.isOutlier ? " (left out)" : ""
        return "\(date) · \(food)\(formatUnits(episode.bolusUnits)) u · \(glucose) · \(formatTherapyNumber(rounded(episode.value))) \(unit)\(outlier)"
    }
}

/// Accepted and hand-made changes to sensitivity and carb ratio, newest first.
public struct TherapyChangeLogRows: View {
    let changes: [TherapyChange]

    public init(changes: [TherapyChange]) {
        self.changes = changes
    }

    public var body: some View {
        if changes.isEmpty {
            Text("No changes yet.").foregroundStyle(.secondary)
        } else {
            ForEach(changes.reversed()) { change in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(change.quantity == .carbRatio ? "Carb ratio" : "Insulin sensitivity") \(change.old.map(formatTherapyNumber) ?? "not set") → \(change.new.map(formatTherapyNumber) ?? "not set")")
                    Text("\(change.date.formatted(date: .abbreviated, time: .shortened)) · \(change.evidence)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
