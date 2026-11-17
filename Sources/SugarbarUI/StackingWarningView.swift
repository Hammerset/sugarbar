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
                Text("Still to lower glucose by about \(formatMmolPerL(remaining)) mmol/L over the next ~\(formatHalfHours(warning.remainingDuration)).")
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

    private func withDoseLine(_ effect: Double) -> String {
        let lead = "With this \(formatUnits(doseUnits)) u: about \(formatMmolPerL(effect)) mmol/L"
        guard let latest = warning.latest, let after = warning.glucoseAfterDose else { return lead + "." }
        let end = after < forecastValueRange.lowerBound
            ? "below \(formatMmolPerL(forecastValueRange.lowerBound))"
            : "near \(formatMmolPerL(after))"
        return lead + ", so from \(formatMmolPerL(latest.value)) glucose would end \(end) mmol/L from insulin alone."
    }

    private func rounded(_ units: Double) -> Double { (units * 10).rounded() / 10 }

    private func formatGap(_ seconds: TimeInterval) -> String {
        let minutes = Int((max(0, seconds) / 60).rounded())
        return minutes < 90 ? "\(minutes) min" : formatHalfHours(seconds)
    }

    public static let caution = "Correcting during a post-meal rise with insulin on board can stack and cause a low. Carbs still being absorbed are not counted. This is information, not a dosing instruction."

    public static func saveTitle(_ warning: StackingWarning?, base: String = "Save") -> String {
        warning == nil ? base : "\(base) Anyway"
    }
}

func formatHalfHours(_ seconds: TimeInterval) -> String {
    let halves = Int((seconds / 1800).rounded())
    if halves < 2 { return "\(max(halves, 0) * 30) min" }
    return "\(halves / 2)\(halves % 2 == 1 ? "½" : "") h"
}
