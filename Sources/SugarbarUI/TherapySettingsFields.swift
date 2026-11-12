import SwiftUI
import SugarbarCore

/// The therapy-setting rows shared by the Mac settings window and the iOS sheet.
public struct TherapySettingsFields: View {
    @Binding var therapy: TherapySettings

    public init(therapy: Binding<TherapySettings>) {
        _therapy = therapy
    }

    public static let note = "Used to forecast where glucose is heading and to calculate the Suggested Dose when you plan a meal. Check every number; you decide."

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
        Stepper(value: hours(\.carbAbsorptionTime), in: hoursRange(TherapySettings.carbAbsorptionRange), step: 0.5) {
            LabeledContent("Carb absorption", value: "\(formatHours(therapy.carbAbsorptionTime)) h")
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
        return hours == hours.rounded() ? String(format: "%.0f", hours) : String(format: "%.1f", hours)
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
