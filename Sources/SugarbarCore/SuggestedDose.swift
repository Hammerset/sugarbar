import Foundation

/// What the Suggested Dose aims for and how it is rounded and capped. Separate from Therapy Settings,
/// which describe the body; these describe the pen and the user's choices.
public struct DosingSettings: Equatable, Sendable, Codable {
    /// mmol/L the correction part aims for.
    public var targetGlucose: Double
    /// Smallest amount the pen can dial, in units.
    public var penStep: Double
    /// The Suggested Dose never exceeds this, in units.
    public var maxSingleDose: Double

    public init(targetGlucose: Double = 6.0, penStep: Double = 1, maxSingleDose: Double = 15) {
        self.targetGlucose = targetGlucose
        self.penStep = penStep
        self.maxSingleDose = maxSingleDose
    }

    public static let `default` = DosingSettings()

    public static let targetRange: ClosedRange<Double> = 4.5...10
    public static let penSteps: [Double] = [0.5, 1]
    public static let maxSingleDoseRange: ClosedRange<Double> = 1...50

    private enum CodingKeys: String, CodingKey {
        case targetGlucose, penStep, maxSingleDose
    }

    /// Missing or out-of-range values fall back to the defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = DosingSettings.default
        let target = (try? container.decodeIfPresent(Double.self, forKey: .targetGlucose)) ?? nil
        let step = (try? container.decodeIfPresent(Double.self, forKey: .penStep)) ?? nil
        let cap = (try? container.decodeIfPresent(Double.self, forKey: .maxSingleDose)) ?? nil
        targetGlucose = target.flatMap { Self.targetRange.contains($0) ? $0 : nil } ?? fallback.targetGlucose
        penStep = step.flatMap { Self.penSteps.contains($0) ? $0 : nil } ?? fallback.penStep
        maxSingleDose = cap.flatMap { Self.maxSingleDoseRange.contains($0) ? $0 : nil } ?? fallback.maxSingleDose
    }
}

/// Why the app gives no Suggested Dose right now.
public enum DoseWithheldReason: Equatable, Sendable {
    case noTherapySettings
    case noReading
    case staleReading
    case sensorWarmingUp
    case outsideSensorRange
    case glucoseLow
    case insulinOnBoardUnknown

    public var message: String {
        switch self {
        case .noTherapySettings:
            "A dose suggestion needs your carb ratio and insulin sensitivity, typed in under Therapy Settings or learned from your Meals and Doses."
        case .noReading:
            "No current Reading to calculate a correction from."
        case .staleReading:
            "The latest Reading is more than 5 minutes old. Wait for a fresh one."
        case .sensorWarmingUp:
            "The sensor is warming up, so there is no Reading to calculate from."
        case .outsideSensorRange:
            "The sensor shows LO or HI. Check with a fingerstick before dosing."
        case .glucoseLow:
            "Glucose is low. Treat the low first; no bolus is suggested."
        case .insulinOnBoardUnknown:
            "Insulin on Board could not be worked out, so no dose is suggested."
        }
    }
}

/// The app's calculation for a meal, with every part shown so the user can check it.
public struct SuggestedDose: Equatable, Sendable {
    public let carbsGrams: Double
    public let carbRatio: Double
    public let insulinSensitivity: Double
    public let currentGlucose: Double
    public let targetGlucose: Double
    /// carbs ÷ carb ratio.
    public let mealUnits: Double
    /// (current − target) ÷ sensitivity; negative below target.
    public let correctionUnits: Double
    public let insulinOnBoard: Double
    /// The part of Insulin on Board taken off; never more than meal + correction.
    public let insulinOnBoardDeduction: Double
    /// meal + correction − deduction, after the cap, before rounding.
    public let unroundedUnits: Double
    /// Rounded down to the pen step.
    public let units: Double
    public let penStep: Double
    public let wasCapped: Bool
    public let maxSingleDose: Double
}

public enum DoseSuggestion: Equatable, Sendable {
    case suggested(SuggestedDose)
    case withheld([DoseWithheldReason])

    public var dose: SuggestedDose? {
        if case let .suggested(dose) = self { return dose }
        return nil
    }

    public var withheldReasons: [DoseWithheldReason] {
        if case let .withheld(reasons) = self { return reasons }
        return []
    }
}

public struct DoseSuggestionInput: Equatable, Sendable {
    public var carbsGrams: Double
    public var therapy: TherapySettings
    public var dosing: DosingSettings
    public var thresholds: Thresholds
    public var latest: Reading?
    public var sensorActivation: Date?
    public var insulinOnBoard: Double?
    public var now: Date

    public init(
        carbsGrams: Double,
        therapy: TherapySettings,
        dosing: DosingSettings,
        thresholds: Thresholds,
        latest: Reading?,
        sensorActivation: Date?,
        insulinOnBoard: Double?,
        now: Date
    ) {
        self.carbsGrams = carbsGrams
        self.therapy = therapy
        self.dosing = dosing
        self.thresholds = thresholds
        self.latest = latest
        self.sensorActivation = sensorActivation
        self.insulinOnBoard = insulinOnBoard
        self.now = now
    }
}

/// carbs ÷ ratio + (current − target) ÷ sensitivity − Insulin on Board, never below zero, capped at the
/// maximum single dose and rounded down to the pen step. Withheld without complete Therapy Settings,
/// a fresh in-range Reading, or while glucose is low.
public func suggestDose(_ input: DoseSuggestionInput) -> DoseSuggestion {
    var reasons: [DoseWithheldReason] = []
    let therapy = input.therapy
    if !therapy.isComplete || !therapy.isValid { reasons.append(.noTherapySettings) }
    if let latest = input.latest {
        if warmUpRemaining(activatedAt: input.sensorActivation, now: input.now) != nil {
            reasons.append(.sensorWarmingUp)
        } else if latest.isStale(at: input.now) {
            reasons.append(.staleReading)
        } else if latest.outOfRange == .high {
            reasons.append(.outsideSensorRange)
        } else if latest.value < input.thresholds.low {
            reasons = [.glucoseLow]
        }
    } else {
        reasons.append(warmUpRemaining(activatedAt: input.sensorActivation, now: input.now) != nil ? .sensorWarmingUp : .noReading)
    }
    if reasons.isEmpty, input.insulinOnBoard == nil { reasons.append(.insulinOnBoardUnknown) }
    guard reasons.isEmpty,
          let latest = input.latest,
          let ratio = therapy.carbRatio,
          let sensitivity = therapy.insulinSensitivity,
          let onBoard = input.insulinOnBoard
    else { return .withheld(reasons) }

    let dosing = input.dosing
    let mealUnits = max(0, input.carbsGrams) / ratio
    let correctionUnits = (latest.value - dosing.targetGlucose) / sensitivity
    let beforeDeduction = mealUnits + correctionUnits
    let deduction = min(max(0, onBoard), max(0, beforeDeduction))
    let uncapped = max(0, beforeDeduction - deduction)
    let wasCapped = uncapped > dosing.maxSingleDose
    let unrounded = min(uncapped, dosing.maxSingleDose)
    let units = roundDown(unrounded, toStep: dosing.penStep)

    return .suggested(SuggestedDose(
        carbsGrams: max(0, input.carbsGrams),
        carbRatio: ratio,
        insulinSensitivity: sensitivity,
        currentGlucose: latest.value,
        targetGlucose: dosing.targetGlucose,
        mealUnits: mealUnits,
        correctionUnits: correctionUnits,
        insulinOnBoard: max(0, onBoard),
        insulinOnBoardDeduction: deduction,
        unroundedUnits: unrounded,
        units: units,
        penStep: dosing.penStep,
        wasCapped: wasCapped,
        maxSingleDose: dosing.maxSingleDose
    ))
}

/// The tolerance keeps a value like 5.9999999 from losing a whole step to floating-point error.
public func roundDown(_ units: Double, toStep step: Double) -> Double {
    guard step > 0 else { return units }
    return (units / step + 1e-6).rounded(.down) * step
}
