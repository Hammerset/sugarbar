import Foundation

/// What the user sees before saving a Bolus that would stack on insulin still acting.
/// Informational: it never blocks the Dose and never suggests an amount.
public struct StackingWarning: Equatable, Sendable {
    /// Bolus units still to act when the new Bolus is given.
    public let insulinOnBoard: Double
    /// When the previous Bolus was given; nil when there is none.
    public let previousBolusTime: Date?
    /// Units of the previous Bolus, counting every Bolus within `stackingGroupWindow` before it as the same one.
    public let previousBolusUnits: Double
    public let insulinOnBoardAboveLimit: Bool
    public let previousBolusIsRecent: Bool
    /// How long until every Bolus counted in Insulin on Board has finished acting.
    public let remainingDuration: TimeInterval
    /// mmol/L that Insulin on Board is still to lower glucose by; nil without insulin sensitivity.
    public let remainingEffect: Double?
    /// The same including the Bolus being entered.
    public let effectWithDose: Double?
    /// Grams of eaten Meals not yet absorbed when the new Bolus is given.
    public let carbsOnBoard: Double
    /// mmol/L those carbs are still to raise glucose by; nil without insulin sensitivity or carb ratio.
    public let remainingCarbEffect: Double?
    /// Nil without a fresh, in-range Reading.
    public let latest: Reading?
    /// Current glucose minus `effectWithDose`, plus `remainingCarbEffect` when there is one.
    public let glucoseAfterDose: Double?
    public let endsBelowLow: Bool
}

/// Boluses this close together read as one injection split across pens or sites.
public let stackingGroupWindow: TimeInterval = 15 * 60

/// Nil for Basal, or when Insulin on Board is at or below the setting and the previous Bolus
/// is at least the stacking interval before `timestamp`. `doses` must not include the one being entered.
/// Carbs absorb as in the Forecast but without its retrospective slow-down, which needs the recent Readings' fit.
public func stackingWarning(
    units: Double,
    kind: InsulinKind,
    timestamp: Date,
    doses: [InsulinDose],
    meals: [Meal],
    latest: Reading?,
    therapy: TherapySettings,
    dosing: DosingSettings,
    thresholds: Thresholds,
    now: Date
) -> StackingWarning? {
    guard kind == .bolus else { return nil }
    let timing = therapy.insulinPeak > 0 && therapy.insulinPeak * 2 < therapy.insulinDuration ? therapy : .default
    let model = ExponentialInsulinModel(peak: timing.insulinPeak, duration: timing.insulinDuration)
    let earlier = doses.filter { $0.kind == .bolus && $0.timestamp <= timestamp }
    let acting = earlier.filter { timestamp.timeIntervalSince($0.timestamp) < timing.insulinDuration }
    let onBoard = acting.reduce(0) { $0 + $1.units * model.remainingFraction(after: timestamp.timeIntervalSince($1.timestamp)) }
    let previous = earlier.max { $0.timestamp < $1.timestamp }
    let previousUnits = previous.map { last in
        earlier.filter { last.timestamp.timeIntervalSince($0.timestamp) <= stackingGroupWindow }.reduce(0) { $0 + $1.units }
    } ?? 0
    let aboveLimit = onBoard > dosing.stackingInsulinOnBoard
    let recent = previous.map { timestamp.timeIntervalSince($0.timestamp) < dosing.stackingInterval } ?? false
    guard aboveLimit || recent else { return nil }

    let sensitivity = therapy.insulinSensitivity.flatMap { TherapySettings.sensitivityRange.contains($0) ? $0 : nil }
    let effectWithDose = sensitivity.map { (onBoard + max(0, units)) * $0 }
    let carbRatio = therapy.carbRatio.flatMap { TherapySettings.carbRatioRange.contains($0) ? $0 : nil }
    let carbsOnBoard = meals
        .filter { $0.isEaten && $0.timestamp <= timestamp }
        .reduce(0) { $0 + $1.carbsGrams - $1.carbsAbsorbed(at: timestamp, therapy: timing) }
    let carbEffect = sensitivity.flatMap { isf in carbRatio.map { carbsOnBoard * isf / $0 } }
    let fresh = latest.flatMap { !$0.isStale(at: now) && $0.outOfRange == nil ? $0 : nil }
    let glucoseAfter = fresh.flatMap { reading in effectWithDose.map { reading.value - $0 + (carbEffect ?? 0) } }
    let lastEnd = acting.map { $0.timestamp.addingTimeInterval(timing.insulinDuration) }.max()

    return StackingWarning(
        insulinOnBoard: onBoard,
        previousBolusTime: previous?.timestamp,
        previousBolusUnits: previousUnits,
        insulinOnBoardAboveLimit: aboveLimit,
        previousBolusIsRecent: recent,
        remainingDuration: max(0, lastEnd?.timeIntervalSince(timestamp) ?? 0),
        remainingEffect: sensitivity.map { onBoard * $0 },
        effectWithDose: effectWithDose,
        carbsOnBoard: carbsOnBoard,
        remainingCarbEffect: carbEffect,
        latest: fresh,
        glucoseAfterDose: glucoseAfter,
        endsBelowLow: glucoseAfter.map { $0 < thresholds.low } ?? false
    )
}

/// The Stacking Warning for a Bolus being entered now, from History's reconciled Doses.
public func stackingWarningFromHistory(
    _ history: HistoryStore,
    meals: [Meal],
    units: Double,
    kind: InsulinKind,
    timestamp: Date,
    latest: Reading?,
    settings: Settings,
    now: Date
) -> StackingWarning? {
    let lookback = max(settings.therapy.insulinDuration, settings.dosing.stackingInterval)
    return stackingWarning(
        units: units,
        kind: kind,
        timestamp: timestamp,
        doses: history.doses(in: timestamp.addingTimeInterval(-lookback)...timestamp),
        meals: meals,
        latest: latest,
        therapy: settings.therapy,
        dosing: settings.dosing,
        thresholds: settings.thresholds,
        now: now
    )
}
