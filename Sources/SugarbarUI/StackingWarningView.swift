import SwiftUI
import SugarbarCore

/// The Stacking Warning shown inside Dose entry, above the save button.
public struct StackingWarningView: View {
    private let warning: StackingWarning
    private let doseUnits: Double
    private let doseTime: Date

    public init(warning: StackingWarning, doseUnits: Double, doseTime: Date) {
        self.warning = warning
        self.doseUnits = doseUnits
        self.doseTime = doseTime
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Insulin on board: \(formatUnits(rounded(warning.insulinOnBoard))) u", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
            if let previous = warning.previousBolusTime {
                Text("Previous bolus \(formatUnits(warning.previousBolusUnits)) u at \(previous.formatted(.dateTime.hour().minute())), \(formatGap(doseTime.timeIntervalSince(previous))) before this one.")
            }
            if let remaining = warning.remainingEffect {
                Text("Insulin still to act: −\(formatMmolPerL(remaining)) mmol/L over the next ~\(formatHalfHours(warning.remainingDuration)).")
            }
            if warning.carbsOnBoard >= 0.5 {
                if let carbs = warning.remainingCarbEffect {
                    Text("Carbs still to absorb (\(formatGrams(warning.carbsOnBoard)) g): +\(formatMmolPerL(carbs)) mmol/L.")
                } else if warning.remainingEffect != nil {
                    Text("Carbs on board (\(formatGrams(warning.carbsOnBoard)) g) are not counted without a carb ratio in Therapy Settings.")
                }
            }
            if let latest = warning.latest {
                Text("Glucose now \(formatMmolPerL(latest.value)) mmol/L\(latest.trend.arrowText.map { " \($0)" } ?? ""), \(latest.trend.label).")
            }
            if let withDose = warning.effectWithDose, doseUnits > 0 {
                Text(withDoseLine(withDose))
                    .fontWeight(warning.endsBelowLow ? .semibold : .regular)
                    .foregroundStyle(warning.endsBelowLow ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
            }
            Text(Self.caution)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func withDoseLine(_ insulin: Double) -> String {
        let lead = "With this \(formatUnits(doseUnits)) u: insulin −\(formatMmolPerL(insulin)) mmol/L"
        guard let after = warning.glucoseAfterDose else { return lead + "." }
        let end = after < forecastValueRange.lowerBound
            ? "below \(formatMmolPerL(forecastValueRange.lowerBound))"
            : "about \(formatMmolPerL(after))"
        let basis = warning.remainingCarbEffect == nil ? " from insulin alone" : ""
        return lead + ", ending \(end) mmol/L\(basis)."
    }

    private func rounded(_ units: Double) -> Double { (units * 10).rounded() / 10 }

    private func formatGap(_ seconds: TimeInterval) -> String {
        let minutes = Int((max(0, seconds) / 60).rounded())
        return minutes < 90 ? "\(minutes) min" : formatHalfHours(seconds)
    }

    public static let caution = "Correcting during a post-meal rise with insulin on board can stack and cause a low."

    public static func saveTitle(_ warning: StackingWarning?, base: String = "Save") -> String {
        warning == nil ? base : "\(base) Anyway"
    }
}

func formatHalfHours(_ seconds: TimeInterval) -> String {
    let halves = Int((seconds / 1800).rounded())
    if halves < 2 { return "\(max(halves, 0) * 30) min" }
    return "\(halves / 2)\(halves % 2 == 1 ? "½" : "") h"
}
