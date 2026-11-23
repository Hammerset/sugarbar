import Foundation

/// The horizons a Forecast is scored at, in minutes.
public let forecastScoreHorizons = [15, 30, 60, 120]

/// What was going on when a Forecast was made, for splitting its errors.
public enum ForecastSituation: Hashable, Sendable, CaseIterable {
    /// Within 4 hours of a Meal, by the newest one's absorption.
    case afterMeal(CarbAbsorption)
    /// Within 4 hours of a Bolus with no Meal near it.
    case afterCorrection
    /// Midnight to 6 with nothing else going on.
    case overnight
    case quiet

    public static let allCases: [ForecastSituation] = CarbAbsorption.allCases.map { .afterMeal($0) } + [.afterCorrection, .overnight, .quiet]

    public var label: String {
        switch self {
        case let .afterMeal(speed): "After a \(speed.label.lowercased()) meal"
        case .afterCorrection: "After a correction"
        case .overnight: "Overnight"
        case .quiet: "Quiet"
        }
    }
}

let situationWindow = 4 * 60
/// A Bolus this close to a Meal is that Meal's Bolus, not a correction.
let mealBolusLink = 45

public func forecastSituation(_ entry: ForecastLogEntry, calendar: Calendar) -> ForecastSituation {
    if let meal = entry.meals.filter({ $0.minutesAgo >= 0 && $0.minutesAgo <= situationWindow }).min(by: { $0.minutesAgo < $1.minutesAgo }) {
        return .afterMeal(meal.absorption)
    }
    let correction = entry.boluses.contains { bolus in
        bolus.minutesAgo >= 0 && bolus.minutesAgo <= situationWindow
            && !entry.meals.contains { abs($0.minutesAgo - bolus.minutesAgo) <= mealBolusLink }
    }
    if correction { return .afterCorrection }
    let hour = calendar.component(.hour, from: entry.date)
    return hour < 6 ? .overnight : .quiet
}

/// Mean absolute error and bias (predicted minus actual, so positive means the Forecast read high).
public struct ForecastError: Equatable, Sendable {
    public let count: Int
    public let meanAbsoluteError: Double
    public let bias: Double

    public static let empty = ForecastError(count: 0, meanAbsoluteError: .nan, bias: .nan)

    init(errors: [Double]) {
        count = errors.count
        meanAbsoluteError = errors.isEmpty ? .nan : errors.reduce(0) { $0 + abs($1) } / Double(errors.count)
        bias = errors.isEmpty ? .nan : errors.reduce(0, +) / Double(errors.count)
    }

    init(count: Int, meanAbsoluteError: Double, bias: Double) {
        self.count = count
        self.meanAbsoluteError = meanAbsoluteError
        self.bias = bias
    }
}

/// How one kind of early warning did: a warning is right when the event follows it.
public struct AlertScore: Equatable, Sendable {
    public let hits: Int
    public let falseAlarms: Int
    /// Events no warning came before, while the device was making Forecasts.
    public let misses: Int
    /// Mean time from the first warning to the event, over hits.
    public let meanLeadTime: TimeInterval?

    public var warnings: Int { hits + falseAlarms }
}

public struct ForecastScorecard: Equatable, Sendable {
    public let interval: ClosedRange<Date>
    public let forecastCount: Int
    /// Per horizon in `forecastScoreHorizons`, over every Forecast with a Reading at that horizon.
    public let overall: [Int: ForecastError]
    public let bySituation: [ForecastSituation: [Int: ForecastError]]
    public let headingLow: AlertScore
    public let fallingFast: AlertScore

    public func error(atMinute minute: Int) -> ForecastError { overall[minute] ?? .empty }
}

/// Readings within this of a target time are taken as they are.
let exactMatchTolerance: TimeInterval = 90
/// Between two Readings further apart than this, glucose is unknown.
let interpolationMaximumGap: TimeInterval = 16 * 60

/// Glucose at `date`: a Reading within 90 s, else a line between the Readings either side when
/// they are at most 16 minutes apart. Nil across a gap, past the last Reading, or at LO/HI.
func actualGlucose(at date: Date, sortedReadings readings: [Reading]) -> Double? {
    let index = readings.partitioningIndex { $0.timestamp >= date }
    let after = index < readings.count ? readings[index] : nil
    let before = index > 0 ? readings[index - 1] : nil
    let nearest = [before, after].compactMap(\.self).min { abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date)) }
    if let nearest, abs(nearest.timestamp.timeIntervalSince(date)) <= exactMatchTolerance {
        return nearest.outOfRange == nil ? nearest.value : nil
    }
    guard let before, let after, before.outOfRange == nil, after.outOfRange == nil else { return nil }
    let span = after.timestamp.timeIntervalSince(before.timestamp)
    guard span <= interpolationMaximumGap, span > 0 else { return nil }
    let share = date.timeIntervalSince(before.timestamp) / span
    return before.value + (after.value - before.value) * share
}

public struct AlertScoringRules: Equatable, Sendable {
    public var predictedLowLead: TimeInterval
    public var fallingFastThreshold: Double
    public var fallingFastWindow: TimeInterval
    /// An event this soon after a warning's window still counts as caught.
    public var grace: TimeInterval = 10 * 60

    public init(alerts: AlertSettings) {
        predictedLowLead = min(alerts.predictedLowLead, 60 * 60)
        fallingFastThreshold = alerts.fallingFastThreshold
        fallingFastWindow = min(alerts.fallingFastWindow, 60 * 60)
    }
}

/// Matches each logged Forecast to the Readings that followed and reports its errors per horizon
/// and situation, and how its heading-low and falling-fast warnings turned out. Horizons whose
/// time is after `now`, or fall in a gap in the Readings, are left out.
public func scoreForecasts(
    _ entries: [ForecastLogEntry],
    readings: [Reading],
    rules: AlertScoringRules,
    now: Date,
    calendar: Calendar = .current
) -> ForecastScorecard {
    let sorted = readings.sorted { $0.timestamp < $1.timestamp }
    let entries = entries.sorted { $0.date < $1.date }
    var errors: [Int: [Double]] = [:]
    var bySituation: [ForecastSituation: [Int: [Double]]] = [:]
    for entry in entries {
        let situation = forecastSituation(entry, calendar: calendar)
        for minute in forecastScoreHorizons {
            let target = entry.date.addingTimeInterval(Double(minute) * 60)
            guard target <= now,
                  let predicted = entry.predicted(atMinute: minute),
                  let actual = actualGlucose(at: target, sortedReadings: sorted)
            else { continue }
            errors[minute, default: []].append(predicted - actual)
            bySituation[situation, default: [:]][minute, default: []].append(predicted - actual)
        }
    }
    let interval = (entries.first?.date ?? now)...max(entries.last?.date ?? now, entries.first?.date ?? now)
    return ForecastScorecard(
        interval: interval,
        forecastCount: entries.count,
        overall: errors.mapValues(ForecastError.init(errors:)),
        bySituation: bySituation.mapValues { $0.mapValues(ForecastError.init(errors:)) },
        headingLow: scoreAlerts(
            entries, readings: sorted, now: now, window: rules.predictedLowLead, grace: rules.grace,
            threshold: { $0.lowThreshold },
            warns: { entry in
                guard entry.glucose >= entry.lowThreshold, let lowest = entry.lowestPredicted(within: rules.predictedLowLead) else { return false }
                return lowest < entry.lowThreshold
            }
        ),
        fallingFast: scoreAlerts(
            entries, readings: sorted, now: now, window: rules.fallingFastWindow, grace: rules.grace,
            threshold: { _ in rules.fallingFastThreshold },
            warns: { entry in
                guard entry.glucose >= entry.lowThreshold, (entry.trendRate ?? 0) < 0,
                      let lowest = entry.lowestPredicted(within: rules.fallingFastWindow)
                else { return false }
                return lowest < rules.fallingFastThreshold
            }
        )
    )
}

/// Consecutive warning Forecasts at most this far apart are one warning.
let warningMergeGap: TimeInterval = 15 * 60
/// Glucose has to be back above the threshold this long before another crossing is a new event.
let eventSeparation: TimeInterval = 30 * 60

private func scoreAlerts(
    _ entries: [ForecastLogEntry],
    readings: [Reading],
    now: Date,
    window: TimeInterval,
    grace: TimeInterval,
    threshold: (ForecastLogEntry) -> Double,
    warns: (ForecastLogEntry) -> Bool
) -> AlertScore {
    guard let first = entries.first else { return AlertScore(hits: 0, falseAlarms: 0, misses: 0, meanLeadTime: nil) }
    let level = threshold(entries.last ?? first)

    var events: [Date] = []
    var lastBelow: Date?
    var previous: Reading?
    for reading in readings where reading.timestamp >= first.date && reading.outOfRange == nil {
        defer { previous = reading }
        guard reading.value < level else { continue }
        let crossed = previous.map { $0.value >= level } ?? false
        if crossed, lastBelow.map({ reading.timestamp.timeIntervalSince($0) > eventSeparation }) ?? true {
            events.append(reading.timestamp)
        }
        lastBelow = reading.timestamp
    }

    var warnings: [(start: Date, end: Date)] = []
    for entry in entries where warns(entry) {
        if let open = warnings.last, entry.date.timeIntervalSince(open.end) <= warningMergeGap {
            warnings[warnings.count - 1].end = entry.date
        } else {
            warnings.append((entry.date, entry.date))
        }
    }

    var hits = 0
    var falseAlarms = 0
    var leads: [TimeInterval] = []
    var caught = Set<Date>()
    for warning in warnings {
        let deadline = warning.end.addingTimeInterval(window + grace)
        guard deadline <= now || events.contains(where: { $0 >= warning.start && $0 <= deadline }) else { continue }
        if let event = events.first(where: { $0 >= warning.start && $0 <= deadline }) {
            hits += 1
            leads.append(event.timeIntervalSince(warning.start))
            caught.insert(event)
        } else {
            falseAlarms += 1
        }
    }
    let covered = events.filter { event in
        !caught.contains(event) && entries.contains { $0.date <= event && event.timeIntervalSince($0.date) <= window }
    }
    let misses = covered.filter { event in !warnings.contains { $0.start <= event && event <= $0.end.addingTimeInterval(window + grace) } }.count
    return AlertScore(
        hits: hits,
        falseAlarms: falseAlarms,
        misses: misses,
        meanLeadTime: leads.isEmpty ? nil : leads.reduce(0, +) / Double(leads.count)
    )
}

public extension ForecastScorecard {
    /// "±0.9 mmol/L at 30 min, ±1.6 at 60 min; 5 of 6 low warnings right", or nil with too little to say.
    var summaryLine: String? {
        let thirty = error(atMinute: 30)
        let sixty = error(atMinute: 60)
        guard thirty.count >= minimumScoredForecasts else { return nil }
        var line = "±\(formatOneDecimal(thirty.meanAbsoluteError)) mmol/L at 30 min"
        if sixty.count >= minimumScoredForecasts {
            line += ", ±\(formatOneDecimal(sixty.meanAbsoluteError)) at 60 min"
        }
        if headingLow.warnings > 0 {
            line += "; \(headingLow.hits) of \(headingLow.warnings) low \(headingLow.warnings == 1 ? "warning" : "warnings") right"
        }
        return line
    }
}

/// Fewer scored Forecasts than this at a horizon say nothing worth showing.
public let minimumScoredForecasts = 24

func formatOneDecimal(_ value: Double) -> String { String(format: "%.1f", value) }
