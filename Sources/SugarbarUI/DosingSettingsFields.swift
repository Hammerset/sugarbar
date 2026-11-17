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
        Stepper(value: $dosing.stackingInsulinOnBoard, in: DosingSettings.stackingInsulinOnBoardRange, step: 0.5) {
            LabeledContent("Warn above insulin on board", value: "\(formatUnits(dosing.stackingInsulinOnBoard)) u")
        }
        Stepper(value: $dosing.stackingInterval, in: DosingSettings.stackingIntervalRange, step: 30 * 60) {
            LabeledContent("Warn within", value: "\(formatHalfHours(dosing.stackingInterval)) of a bolus")
        }
    }

    public static let note = "Used by Plan Meal: carbs ÷ carb ratio plus a correction to the target ÷ insulin sensitivity, minus Insulin on Board, rounded down to the pen step and never above the maximum. A calculation for you to check, not a medical device. Logging a bolus above that insulin on board, or that soon after the previous bolus, shows a stacking warning before saving."
}
