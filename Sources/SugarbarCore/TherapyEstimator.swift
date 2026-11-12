import Foundation

public enum TherapyQuantity: String, Codable, Sendable, CaseIterable {
    case insulinSensitivity
    case carbRatio
}

public enum TimeOfDay: String, Codable, Sendable, CaseIterable {
    case morning
    case midday
    case evening
    case night

    public init(hour: Int) {
        switch hour {
        case 5..<11: self = .morning
        case 11..<16: self = .midday
        case 16..<22: self = .evening
        default: self = .night
        }
    }

    public var label: String {
        switch self {
        case .morning: "Morning"
        case .midday: "Midday"
        case .evening: "Evening"
        case .night: "Night"
        }
    }
}

public struct TherapyEstimationOptions: Equatable, Sendable {
    /// How far back History is searched for Episodes.
    public var lookback: TimeInterval = 28 * 86400
    /// An Episode this old counts half as much as one from today.
    public var halfLife: TimeInterval = 7 * 86400
    /// Episodes that end this recently are skipped: Pen Doses reach History late.
    public var settleTime: TimeInterval = 12 * 3600
    /// A Suggestion needs the estimate to differ from the working value by more than this share.
    public var suggestionMargin = 0.10
    public var minimumEpisodes = 5
    public var minimumEffectiveSampleSize = 3.0
    public var minimumDays = 3
    /// Largest relative standard error of an estimate that may become a Suggestion.
    public var maximumRelativeError = 0.12
    public var minimumEpisodesPerTimeOfDay = 4
    /// The window closes once at most this share of the Episode's insulin is still to act.
    public var maximumRemainingInsulin = 0.15

    public init() {}

    public static let `default` = TherapyEstimationOptions()
}

/// How often the apps re-learn Therapy Settings from History on their own.
public let therapyEstimateInterval: TimeInterval = 6 * 3600

public enum EpisodeKind: String, Sendable {
    case correction
    case meal
}

/// One stretch of History clean enough to learn from: a Bolus with (Meal Episode) or
/// without (Correction Episode) logged carbs, glucose known at both ends.
public struct TherapyEpisode: Equatable, Sendable, Identifiable {
    public let kind: EpisodeKind
    public let start: Date
    public let end: Date
    public let startGlucose: Double
    public let endGlucose: Double
    public let bolusUnits: Double
    /// Bolus units that acted between start and end, including earlier Boluses' tail.
    public let insulinActed: Double
    public let carbsGrams: Double
    /// mmol/L per unit for a Correction Episode, grams per unit for a Meal Episode.
    public let value: Double
    public let weight: Double
    /// Dropped from the estimate as too far from the other Episodes.
    public let isOutlier: Bool
    public let timeOfDay: TimeOfDay

    public var id: Date { start }
}

public struct TimeOfDayEstimate: Equatable, Sendable {
    public let timeOfDay: TimeOfDay
    public let value: Double
    public let episodeCount: Int
}

public struct QuantityEstimate: Equatable, Sendable {
    public let quantity: TherapyQuantity
    public let value: Double
    /// Every Episode considered, newest first, outliers flagged.
    public let episodes: [TherapyEpisode]
    public let effectiveSampleSize: Double
    public let relativeStandardError: Double
    /// Weighted 25th–75th percentile of the Episodes kept.
    public let spread: ClosedRange<Double>
    public let byTimeOfDay: [TimeOfDayEstimate]
    public let hasEnoughEvidence: Bool
    let oldest: Date

    public var keptEpisodes: [TherapyEpisode] { episodes.filter { !$0.isOutlier } }
    public var episodeCount: Int { keptEpisodes.count }
}

public enum CarbRatioBasis: Equatable, Sendable {
    case estimatedSensitivity(Double)
    case workingSensitivity(Double)
}

public enum EpisodeRejection: String, CaseIterable, Sendable {
    case otherMeal = "another Meal in the window"
    case carbsOnBoard = "carbs still absorbing at the start"
    case insulinOnBoard = "too much earlier insulin on board"
    case tooLong = "insulin kept being added"
    case tooSmall = "dose too small to measure"
    case notAboveRange = "correction started in range"
    case missingGlucose = "glucose missing or gapped"
    case sensorClamp = "sensor LO/HI"
    case trendBefore = "glucose already moving fast"
    case treatedLow = "low treated with unlogged carbs"
    case unexplainedRise = "rise with no logged Meal"
    case implausible = "result outside plausible range"
}

public struct TherapySuggestion: Equatable, Sendable {
    public let quantity: TherapyQuantity
    public let current: Double?
    public let suggested: Double
    public let episodeCount: Int
    public let days: Int

    public var evidence: String {
        let noun = quantity == .carbRatio ? (episodeCount == 1 ? "meal" : "meals") : (episodeCount == 1 ? "correction" : "corrections")
        return "\(episodeCount) \(noun) in the last \(days) \(days == 1 ? "day" : "days")"
    }

    public var text: String {
        let name = quantity == .carbRatio ? "Carb ratio" : "Insulin sensitivity"
        let value = formatTherapyValue(suggested, quantity)
        if let current {
            return "\(name) looks closer to \(value) (now \(formatTherapyNumber(current))), from \(evidence)."
        }
        return "\(name) looks like about \(value), from \(evidence)."
    }
}

public struct TherapyEstimate: Equatable, Sendable {
    public let computedAt: Date
    public let sensitivity: QuantityEstimate?
    public let carbRatio: QuantityEstimate?
    public let carbRatioBasis: CarbRatioBasis?
    /// Meal Episodes found but unusable because no sensitivity is known.
    public let unresolvedMealEpisodes: Int
    public let rejections: [EpisodeRejection: Int]
    public let suggestions: [TherapySuggestion]

    public func estimate(_ quantity: TherapyQuantity) -> QuantityEstimate? {
        quantity == .carbRatio ? carbRatio : sensitivity
    }
}

/// "1 u per 8 g" or "1 u per 2.5 mmol/L".
public func formatTherapyValue(_ value: Double, _ quantity: TherapyQuantity) -> String {
    "1 u per \(formatTherapyNumber(value)) \(quantity == .carbRatio ? "g" : "mmol/L")"
}

public func formatTherapyNumber(_ value: Double) -> String {
    value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.1f", value)
}

/// Only eaten Meals with user-confirmed carbs are evidence.
func mealCountsAsEvidence(_ meal: Meal) -> Bool {
    meal.isEaten && meal.carbsGrams > 0
}

/// Learns insulin sensitivity from Correction Episodes and carb ratio from Meal Episodes in
/// History, weighting recent Episodes most. Each Episode follows the Forecast's model:
/// glucose change = carbs × sensitivity ÷ ratio − acted insulin × sensitivity.
public func estimateTherapy(
    readings: [Reading],
    doses: [InsulinDose],
    meals: [Meal],
    therapy: TherapySettings,
    thresholds: Thresholds,
    now: Date,
    options: TherapyEstimationOptions = .default,
    timeZone: TimeZone = .current
) -> TherapyEstimate {
    let from = now.addingTimeInterval(-options.lookback)
    let finder = EpisodeFinder(
        readings: readings.filter { $0.timestamp >= from.addingTimeInterval(-3600) && $0.timestamp <= now }.sorted { $0.timestamp < $1.timestamp },
        boluses: doses.filter { $0.kind == .bolus && $0.units > 0 && $0.timestamp <= now }.sorted { $0.timestamp < $1.timestamp },
        meals: meals.filter { mealCountsAsEvidence($0) && $0.timestamp <= now }.sorted { $0.timestamp < $1.timestamp },
        therapy: therapy,
        thresholds: thresholds,
        options: options
    )
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let (raw, rejections) = finder.episodes(from: from, until: now.addingTimeInterval(-options.settleTime))
    let weight = { (date: Date) in pow(0.5, now.timeIntervalSince(date) / options.halfLife) }

    let corrections = raw.filter { $0.kind == .correction }.map {
        Sample(episode: $0, value: -$0.delta / $0.insulinActed, weight: weight($0.start))
    }
    var rejected = rejections
    let sensitivity = aggregateEstimate(.insulinSensitivity, corrections, range: TherapySettings.sensitivityRange, calendar: calendar, options: options, rejected: &rejected)

    let basis: CarbRatioBasis? = if let sensitivity, sensitivity.hasEnoughEvidence {
        .estimatedSensitivity(sensitivity.value)
    } else if let working = therapy.insulinSensitivity {
        .workingSensitivity(working)
    } else {
        nil
    }
    let mealEpisodes = raw.filter { $0.kind == .meal }
    var carbRatio: QuantityEstimate?
    if let basis {
        let s = switch basis { case let .estimatedSensitivity(v), let .workingSensitivity(v): v }
        let samples = mealEpisodes.map {
            Sample(episode: $0, value: $0.carbs / ($0.delta / s + $0.insulinActed), weight: weight($0.start))
        }
        carbRatio = aggregateEstimate(.carbRatio, samples, range: TherapySettings.carbRatioRange, calendar: calendar, options: options, rejected: &rejected)
    }

    let suggestions = [
        sensitivity.flatMap { suggestion($0, working: therapy.insulinSensitivity, now: now, options: options) },
        carbRatio.flatMap { suggestion($0, working: therapy.carbRatio, now: now, options: options) },
    ].compactMap(\.self)

    return TherapyEstimate(
        computedAt: now,
        sensitivity: sensitivity,
        carbRatio: carbRatio,
        carbRatioBasis: carbRatio == nil ? nil : basis,
        unresolvedMealEpisodes: basis == nil ? mealEpisodes.count : 0,
        rejections: rejected,
        suggestions: suggestions
    )
}

public func estimateTherapy(history: HistoryStore, meals: [Meal], settings: Settings, now: Date = Date(), options: TherapyEstimationOptions = .default) -> TherapyEstimate {
    let span = now.addingTimeInterval(-options.lookback - 12 * 3600)...now
    return estimateTherapy(
        readings: history.readings(in: span),
        doses: history.doses(in: span),
        meals: meals.filter { span.contains($0.timestamp) },
        therapy: settings.therapy,
        thresholds: settings.thresholds,
        now: now,
        options: options
    )
}

private struct RawEpisode {
    let kind: EpisodeKind
    let start: Date
    let end: Date
    let startGlucose: Double
    let endGlucose: Double
    let bolusUnits: Double
    let insulinActed: Double
    let carbs: Double

    var delta: Double { endGlucose - startGlucose }
}

private struct Sample {
    let episode: RawEpisode
    let value: Double
    let weight: Double
}

private let linkWindow: TimeInterval = 45 * 60
private let minimumWindow: TimeInterval = 3 * 3600
private let maximumWindow: TimeInterval = 7 * 3600
private let endStep: TimeInterval = 5 * 60
private let endSpan: TimeInterval = 10 * 60
private let trendSpan: TimeInterval = 30 * 60
private let maximumGap: TimeInterval = 30 * 60
private let maximumTrendBefore = 0.04 / 60
private let riseTolerance = 1.5
private let lowReboundTolerance = 1.0
private let lowReboundSpan: TimeInterval = 60 * 60
private let maximumPriorInsulinShare = 0.5
private let minimumCorrectionUnits = 1.0
private let minimumMealUnits = 0.5
private let minimumMealCarbs = 10.0
private let smoothingHalfWidth: TimeInterval = 7.5 * 60

private struct EpisodeFinder {
    let readings: [Reading]
    let boluses: [InsulinDose]
    let meals: [Meal]
    let therapy: TherapySettings
    let thresholds: Thresholds
    let options: TherapyEstimationOptions

    private var model: ExponentialInsulinModel {
        ExponentialInsulinModel(peak: therapy.insulinPeak, duration: therapy.insulinDuration)
    }

    func episodes(from: Date, until: Date) -> ([RawEpisode], [EpisodeRejection: Int]) {
        guard therapy.insulinPeak > 0, therapy.insulinPeak * 2 < therapy.insulinDuration else { return ([], [:]) }
        let events = (boluses.map(\.timestamp) + meals.map(\.timestamp)).filter { $0 >= from }.sorted()
        var found: [RawEpisode] = []
        var rejections: [EpisodeRejection: Int] = [:]
        var index = 0
        while index < events.count {
            let start = events[index]
            let clusterEnd = start.addingTimeInterval(linkWindow)
            while index < events.count, events[index] <= clusterEnd { index += 1 }
            switch episode(start: start, clusterEnd: clusterEnd, until: until) {
            case let .success(episode):
                found.append(episode)
                while index < events.count, events[index] <= episode.end { index += 1 }
            case let .failure(reason): rejections[reason, default: 0] += 1
            case nil: break
            }
        }
        return (found, rejections)
    }

    private enum Outcome {
        case success(RawEpisode)
        case failure(EpisodeRejection)
    }

    private func episode(start t0: Date, clusterEnd: Date, until: Date) -> Outcome? {
        let clusterMeals = meals.filter { $0.timestamp >= t0 && $0.timestamp <= clusterEnd }
        var included = boluses.filter { $0.timestamp >= t0 && $0.timestamp <= clusterEnd }
        guard !included.isEmpty else { return nil }
        let kind: EpisodeKind = clusterMeals.isEmpty ? .correction : .meal
        let carbs = clusterMeals.reduce(0) { $0 + $1.carbsGrams }
        let carbsDone = clusterMeals.map { $0.timestamp.addingTimeInterval(therapy.carbAbsorptionTime) }.max() ?? t0

        var end: Date
        while true {
            guard let candidate = windowEnd(start: t0, included: included, carbsDone: carbsDone) else { return .failure(.tooLong) }
            end = candidate
            let horizon = end.addingTimeInterval(endSpan)
            if meals.contains(where: { $0.timestamp > clusterEnd && $0.timestamp <= horizon }) { return .failure(.otherMeal) }
            let added = boluses.filter { $0.timestamp > clusterEnd && $0.timestamp <= horizon && !included.contains($0) }
            if added.isEmpty { break }
            included += added
        }
        guard end.addingTimeInterval(endSpan) <= until else { return nil }

        if meals.contains(where: { $0.timestamp < t0 && $0.timestamp >= t0.addingTimeInterval(-therapy.carbAbsorptionTime - 30 * 60) }) {
            return .failure(.carbsOnBoard)
        }
        let units = included.reduce(0) { $0 + $1.units }
        let prior = boluses.filter { $0.timestamp < t0 && $0.timestamp > t0.addingTimeInterval(-therapy.insulinDuration) }
        let priorOnBoard = prior.reduce(0) { $0 + $1.units * model.remainingFraction(after: t0.timeIntervalSince($1.timestamp)) }
        if priorOnBoard > maximumPriorInsulinShare * units { return .failure(.insulinOnBoard) }

        switch kind {
        case .correction: if units < minimumCorrectionUnits { return .failure(.tooSmall) }
        case .meal: if units < minimumMealUnits || carbs < minimumMealCarbs { return .failure(.tooSmall) }
        }

        let window = readings(t0.addingTimeInterval(-trendSpan), end.addingTimeInterval(endSpan))
        if window.contains(where: { $0.outOfRange != nil }) { return .failure(.sensorClamp) }
        let endReadings = window.filter { abs($0.timestamp.timeIntervalSince(end)) <= endSpan }
        guard endReadings.count >= 2, !hasGap(window),
              let trend = trendFit(window.filter { $0.timestamp <= t0 }, at: t0)
        else { return .failure(.missingGlucose) }
        if abs(trend.slope) > maximumTrendBefore { return .failure(.trendBefore) }

        let startGlucose = trend.value
        let endGlucose = mean(endReadings)
        if kind == .correction, startGlucose < thresholds.high { return .failure(.notAboveRange) }

        let during = window.filter { $0.timestamp >= t0 }
        let smoothed = smooth(during)
        if let firstLow = during.first(where: { $0.value < thresholds.low }) {
            let rebound = maxRebound(smoothed, from: firstLow.timestamp, to: firstLow.timestamp.addingTimeInterval(lowReboundSpan))
            if rebound > lowReboundTolerance { return .failure(.treatedLow) }
        }
        let riseFrom: Date = if kind == .meal {
            smoothed.filter { $0.date <= carbsDone }.max { $0.value < $1.value }?.date ?? t0
        } else {
            t0
        }
        let baseline = kind == .correction ? startGlucose : nil
        if maxRebound(smoothed, from: riseFrom, to: end.addingTimeInterval(endSpan), baseline: baseline) > riseTolerance {
            return .failure(.unexplainedRise)
        }

        let acted = included.reduce(0) { $0 + $1.units * (1 - model.remainingFraction(after: end.timeIntervalSince($1.timestamp))) }
            + prior.reduce(0) {
                $0 + $1.units * (model.remainingFraction(after: t0.timeIntervalSince($1.timestamp)) - model.remainingFraction(after: end.timeIntervalSince($1.timestamp)))
            }
        let absorbed = clusterMeals.reduce(0) {
            $0 + $1.carbsGrams * min(max(end.timeIntervalSince($1.timestamp) / therapy.carbAbsorptionTime, 0), 1)
        }
        return .success(RawEpisode(
            kind: kind,
            start: t0,
            end: end,
            startGlucose: startGlucose,
            endGlucose: endGlucose,
            bolusUnits: units,
            insulinActed: acted,
            carbs: absorbed
        ))
    }

    /// The first 5-minute step, at least 3 hours in and after the carbs are absorbed, at which
    /// little enough of the Episode's insulin is still to act; nil if that takes over 7 hours.
    private func windowEnd(start: Date, included: [InsulinDose], carbsDone: Date) -> Date? {
        let units = included.reduce(0) { $0 + $1.units }
        var end = max(start.addingTimeInterval(minimumWindow), carbsDone)
        while end.timeIntervalSince(start) <= maximumWindow {
            let remaining = included.reduce(0) { $0 + $1.units * model.remainingFraction(after: end.timeIntervalSince($1.timestamp)) }
            if remaining <= options.maximumRemainingInsulin * units { return end }
            end.addTimeInterval(endStep)
        }
        return nil
    }

    private func readings(_ from: Date, _ to: Date) -> [Reading] {
        Array(readingsSlice(readings, in: from...to))
    }

    private func hasGap(_ readings: [Reading]) -> Bool {
        zip(readings, readings.dropFirst()).contains { $1.timestamp.timeIntervalSince($0.timestamp) > maximumGap }
    }
}

private struct SmoothedPoint {
    let date: Date
    let value: Double
}

private func mean(_ readings: [Reading]) -> Double {
    readings.reduce(0) { $0 + $1.value } / Double(readings.count)
}

/// Least-squares line through the Readings: its slope (mmol/L per second) and its value at `date`.
/// Nil with fewer than 3 Readings, under 15 minutes of them, or none in the last 10 minutes.
private func trendFit(_ readings: [Reading], at date: Date) -> (slope: Double, value: Double)? {
    guard readings.count >= 3, let first = readings.first, let last = readings.last,
          last.timestamp.timeIntervalSince(first.timestamp) >= 15 * 60,
          date.timeIntervalSince(last.timestamp) <= 10 * 60
    else { return nil }
    let xs = readings.map { $0.timestamp.timeIntervalSince(date) }
    let ys = readings.map(\.value)
    let meanX = xs.reduce(0, +) / Double(xs.count)
    let meanY = ys.reduce(0, +) / Double(ys.count)
    let covariance = zip(xs, ys).reduce(0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) }
    let variance = xs.reduce(0) { $0 + ($1 - meanX) * ($1 - meanX) }
    guard variance > 0 else { return nil }
    let slope = covariance / variance
    return (slope, meanY - slope * meanX)
}

private func smooth(_ readings: [Reading]) -> [SmoothedPoint] {
    var lower = 0
    var upper = 0
    var sum = 0.0
    return readings.map { reading in
        while upper < readings.count, readings[upper].timestamp.timeIntervalSince(reading.timestamp) <= smoothingHalfWidth {
            sum += readings[upper].value
            upper += 1
        }
        while reading.timestamp.timeIntervalSince(readings[lower].timestamp) > smoothingHalfWidth {
            sum -= readings[lower].value
            lower += 1
        }
        return SmoothedPoint(date: reading.timestamp, value: sum / Double(upper - lower))
    }
}

/// The largest climb above the lowest point seen so far (or `baseline`, if lower) within the span.
private func maxRebound(_ points: [SmoothedPoint], from: Date, to: Date, baseline: Double? = nil) -> Double {
    var lowest = baseline ?? .infinity
    var rebound = 0.0
    for point in points where point.date >= from && point.date <= to {
        lowest = min(lowest, point.value)
        rebound = max(rebound, point.value - lowest)
    }
    return rebound
}

/// Recency-weighted geometric mean after dropping Episodes far from the weighted median.
private func aggregateEstimate(
    _ quantity: TherapyQuantity,
    _ samples: [Sample],
    range: ClosedRange<Double>,
    calendar: Calendar,
    options: TherapyEstimationOptions,
    rejected: inout [EpisodeRejection: Int]
) -> QuantityEstimate? {
    let plausible = samples.filter { $0.value.isFinite && range.contains($0.value) }
    if plausible.count < samples.count { rejected[.implausible, default: 0] += samples.count - plausible.count }
    guard let fit = robustFit(plausible) else { return nil }

    let episodes = plausible.enumerated().map { index, sample in
        TherapyEpisode(
            kind: sample.episode.kind,
            start: sample.episode.start,
            end: sample.episode.end,
            startGlucose: sample.episode.startGlucose,
            endGlucose: sample.episode.endGlucose,
            bolusUnits: sample.episode.bolusUnits,
            insulinActed: sample.episode.insulinActed,
            carbsGrams: sample.episode.carbs,
            value: sample.value,
            weight: sample.weight,
            isOutlier: !fit.kept[index],
            timeOfDay: TimeOfDay(hour: calendar.component(.hour, from: sample.episode.start))
        )
    }
    let kept = zip(plausible, fit.kept).filter(\.1).map(\.0)
    let days = Set(kept.map { calendar.startOfDay(for: $0.episode.start) }).count
    let byTimeOfDay = TimeOfDay.allCases.compactMap { slot -> TimeOfDayEstimate? in
        let members = kept.filter { TimeOfDay(hour: calendar.component(.hour, from: $0.episode.start)) == slot }
        guard members.count >= options.minimumEpisodesPerTimeOfDay, let slotFit = robustFit(members) else { return nil }
        return TimeOfDayEstimate(timeOfDay: slot, value: slotFit.value, episodeCount: slotFit.kept.filter(\.self).count)
    }
    return QuantityEstimate(
        quantity: quantity,
        value: fit.value,
        episodes: episodes.sorted { $0.start > $1.start },
        effectiveSampleSize: fit.effectiveSampleSize,
        relativeStandardError: fit.relativeStandardError,
        spread: fit.spread,
        byTimeOfDay: byTimeOfDay,
        hasEnoughEvidence: kept.count >= options.minimumEpisodes
            && fit.effectiveSampleSize >= options.minimumEffectiveSampleSize
            && days >= options.minimumDays
            && fit.relativeStandardError <= options.maximumRelativeError,
        oldest: kept.map(\.episode.start).min() ?? Date()
    )
}

private struct RobustFit {
    let value: Double
    let kept: [Bool]
    let effectiveSampleSize: Double
    let relativeStandardError: Double
    let spread: ClosedRange<Double>
}

private func robustFit(_ samples: [Sample]) -> RobustFit? {
    guard !samples.isEmpty else { return nil }
    let logs = samples.map { log($0.value) }
    let weights = samples.map(\.weight)
    let median = weightedQuantile(logs, weights, 0.5)
    let mad = weightedQuantile(logs.map { abs($0 - median) }, weights, 0.5)
    let cutoff = max(3 * 1.4826 * mad, log(1.3))
    let kept = logs.map { abs($0 - median) <= cutoff }
    let keptLogs = zip(logs, kept).filter(\.1).map(\.0)
    let keptWeights = zip(weights, kept).filter(\.1).map(\.0)
    let total = keptWeights.reduce(0, +)
    guard total > 0 else { return nil }
    let center = zip(keptLogs, keptWeights).reduce(0) { $0 + $1.0 * $1.1 } / total
    let variance = zip(keptLogs, keptWeights).reduce(0) { $0 + $1.1 * pow($1.0 - center, 2) } / total
    let ess = total * total / keptWeights.reduce(0) { $0 + $1 * $1 }
    let standardError = ess > 1 ? sqrt(variance * ess / (ess - 1) / ess) : .infinity
    return RobustFit(
        value: exp(center),
        kept: kept,
        effectiveSampleSize: ess,
        relativeStandardError: standardError,
        spread: exp(weightedQuantile(keptLogs, keptWeights, 0.25))...exp(weightedQuantile(keptLogs, keptWeights, 0.75))
    )
}

func weightedQuantile(_ values: [Double], _ weights: [Double], _ q: Double) -> Double {
    let pairs = zip(values, weights).sorted { $0.0 < $1.0 }
    let total = pairs.reduce(0) { $0 + $1.1 }
    var cumulative = 0.0
    for (value, weight) in pairs {
        cumulative += weight
        if cumulative >= q * total { return value }
    }
    return pairs.last?.0 ?? .nan
}

private func roundedSuggestion(_ value: Double, _ quantity: TherapyQuantity) -> Double {
    quantity == .carbRatio ? (value * 2).rounded() / 2 : (value * 10).rounded() / 10
}

private func suggestion(_ estimate: QuantityEstimate, working: Double?, now: Date, options: TherapyEstimationOptions) -> TherapySuggestion? {
    guard estimate.hasEnoughEvidence else { return nil }
    let suggested = roundedSuggestion(estimate.value, estimate.quantity)
    if let working {
        let distance = abs(log(estimate.value / working))
        guard distance > log(1 + options.suggestionMargin),
              distance > 2 * estimate.relativeStandardError,
              suggested != working
        else { return nil }
    }
    return TherapySuggestion(
        quantity: estimate.quantity,
        current: working,
        suggested: suggested,
        episodeCount: estimate.episodeCount,
        days: max(1, Int(ceil(now.timeIntervalSince(estimate.oldest) / 86400)))
    )
}
