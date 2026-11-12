import SwiftUI
import SugarbarCore

/// Insulin on Board and Carbs on Board next to the current Reading, or a hint when
/// the Forecast is off for lack of Therapy Settings. Nothing in any other no-Forecast case.
public struct OnBoardSummary: View {
    private let forecast: Forecast?
    private let therapyComplete: Bool

    public init(forecast: Forecast?, therapyComplete: Bool) {
        self.forecast = forecast
        self.therapyComplete = therapyComplete
    }

    public var body: some View {
        if let forecast {
            Text("Insulin on board \(formatUnits(forecast.insulinOnBoard)) u · Carbs on board \(formatGrams(forecast.carbsOnBoard)) g")
                .foregroundStyle(.secondary)
        } else if !therapyComplete {
            Text("Enter Therapy Settings to see a forecast.")
                .foregroundStyle(.tertiary)
        }
    }
}
