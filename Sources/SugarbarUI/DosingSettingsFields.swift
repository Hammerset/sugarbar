import SwiftUI
import SugarbarCore

/// The Suggested Dose settings rows shared by the Mac settings window and the iOS sheet.
public struct DosingSettingsFields: View {
    @Binding var dosing: DosingSettings

    public init(dosing: Binding<DosingSettings>) {
        _dosing = dosing
    }

    public var body: some View {
        Stepper(value: $dosing.targetGlucose, in: DosingSettings.targetRange, step: 0.1) {
            LabeledContent("Target glucose", value: "\(formatMmolPerL(dosing.targetGlucose)) mmol/L")
        }
        Picker("Pen dose step", selection: $dosing.penStep) {
            ForEach(DosingSettings.penSteps, id: \.self) { step in
                Text("\(formatUnits(step)) u").tag(step)
            }
        }
        Stepper(value: $dosing.maxSingleDose, in: DosingSettings.maxSingleDoseRange, step: 1) {
            LabeledContent("Maximum single dose", value: "\(formatUnits(dosing.maxSingleDose)) u")
        }
    }

    public static let note = "Used by Plan Meal: carbs ÷ carb ratio plus a correction to the target ÷ insulin sensitivity, minus Insulin on Board, rounded down to the pen step and never above the maximum. A calculation for you to check, not a medical device."
}
