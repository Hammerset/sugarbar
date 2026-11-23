import SwiftUI
import SugarbarCore

/// The therapy-setting rows shared by the Mac settings window and the iOS sheet.
public struct TherapySettingsFields: View {
    @Binding var therapy: TherapySettings

    public init(therapy: Binding<TherapySettings>) {
        _therapy = therapy
    }

    public static let note = "Used to forecast where glucose is heading and to calculate the Suggested Dose when you plan a meal. Each meal absorbs at the speed you pick when logging it. Forecast tuning: how long the CGM trend steers the Forecast, and how far it may slow down or speed up carbs when glucose disagrees."

    public var body: some View {
        LabeledContent("Insulin sensitivity") {
            HStack {
                TextField("mmol/L", value: $therapy.insulinSensitivity, format: .number.precision(.fractionLength(0...1)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 70)
                    .decimalKeyboard()
                Text("mmol/L per unit").foregroundStyle(.secondary)
            }
        }
        LabeledContent("Carb ratio") {
            HStack {
                TextField("grams", value: $therapy.carbRatio, format: .number.precision(.fractionLength(0...1)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 70)
                    .decimalKeyboard()
                Text("g per unit").foregroundStyle(.secondary)
            }
        }
        Stepper(value: hours(\.insulinDuration), in: hoursRange(TherapySettings.insulinDurationRange), step: 0.5) {
            LabeledContent("Insulin duration", value: "\(formatHours(therapy.insulinDuration)) h")
        }
        Stepper(value: minutes(\.insulinPeak), in: minutesRange(TherapySettings.insulinPeakRange), step: 5) {
            LabeledContent("Insulin peak", value: "\(Int(therapy.insulinPeak / 60)) min")
        }
        Stepper(value: hours(\.fastCarbAbsorptionTime), in: hoursRange(TherapySettings.fastCarbAbsorptionRange), step: 0.25) {
            LabeledContent("Fast carb absorption", value: "\(formatHours(therapy.fastCarbAbsorptionTime)) h")
        }
        Stepper(value: hours(\.carbAbsorptionTime), in: hoursRange(TherapySettings.carbAbsorptionRange), step: 0.25) {
            LabeledContent("Normal carb absorption", value: "\(formatHours(therapy.carbAbsorptionTime)) h")
        }
        Stepper(value: hours(\.slowCarbAbsorptionTime), in: hoursRange(TherapySettings.slowCarbAbsorptionRange), step: 0.25) {
            LabeledContent("Slow carb absorption", value: "\(formatHours(therapy.slowCarbAbsorptionTime)) h")
        }
        DisclosureGroup("Forecast tuning") {
            Stepper(value: minutes(\.trendBlendDuration), in: minutesRange(TherapySettings.trendBlendRange), step: 5) {
                LabeledContent("Trend blend", value: "\(Int(therapy.trendBlendDuration / 60)) min")
            }
            Stepper(value: $therapy.slowestCarbFactor, in: TherapySettings.slowestCarbFactorRange, step: 0.05) {
                LabeledContent("Slowest carb correction", value: TherapyQuantity.slowestCarbFactor.format(therapy.slowestCarbFactor))
            }
            Stepper(value: $therapy.fastestCarbFactor, in: TherapySettings.fastestCarbFactorRange, step: 0.05) {
                LabeledContent("Fastest carb correction", value: TherapyQuantity.fastestCarbFactor.format(therapy.fastestCarbFactor))
            }
        }
    }

    private func hours(_ keyPath: WritableKeyPath<TherapySettings, TimeInterval>) -> Binding<Double> {
        Binding(get: { therapy[keyPath: keyPath] / 3600 }, set: { therapy[keyPath: keyPath] = $0 * 3600 })
    }

    private func minutes(_ keyPath: WritableKeyPath<TherapySettings, TimeInterval>) -> Binding<Double> {
        Binding(get: { therapy[keyPath: keyPath] / 60 }, set: { therapy[keyPath: keyPath] = $0 * 60 })
    }

    private func hoursRange(_ range: ClosedRange<TimeInterval>) -> ClosedRange<Double> {
        (range.lowerBound / 3600)...(range.upperBound / 3600)
    }

    private func minutesRange(_ range: ClosedRange<TimeInterval>) -> ClosedRange<Double> {
        (range.lowerBound / 60)...(range.upperBound / 60)
    }

    private func formatHours(_ seconds: TimeInterval) -> String {
        let hours = seconds / 3600
        if hours == hours.rounded() { return String(format: "%.0f", hours) }
        return (hours * 10) == (hours * 10).rounded() ? String(format: "%.1f", hours) : String(format: "%.2f", hours)
    }
}

extension View {
    @ViewBuilder
    func decimalKeyboard() -> some View {
        #if os(iOS)
        keyboardType(.decimalPad)
        #else
        self
        #endif
    }
}
