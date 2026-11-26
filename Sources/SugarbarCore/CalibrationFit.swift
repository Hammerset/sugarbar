import Foundation

public struct CalibrationOptions: Equatable, Sendable {
    public var lookback: TimeInterval = 90 * 86400
    /// The most recent stretch, held out to validate what the older data fitted.
    public var validation: TimeInterval = 7 * 86400
    /// Recent hours are left out: Pen Doses reach History late.
    public var settleTime: TimeInterval = 12 * 3600
    /// Forecasts are replayed this often.
    public var spacing: TimeInterval = 10 * 60
    /// The horizons whose mean absolute errors, averaged, are the fit's error.
    public var horizons = [30, 60, 120]
    public var peaks: [TimeInterval] = stride(from: 45.0, through: 90, by: 5).map { $0 * 60 }
    public var durations: [TimeInterval] = stride(from: 3.0, through: 6, by: 0.5).map { $0 * 3600 }
    public var sensitivities: [Double] = stride(from: 15.0, through: 40, by: 1).map { $0 / 10 }
    /// Carb ratios as a share of the current one, and absorption times, tried on meal episodes.
    public var carbRatioShares: [Double] = stride(from: 0.6, through: 1.4, by: 0.05).map { $0 }
    public var absorptionTimes: [TimeInterval] = stride(from: 0.5, through: 6, by: 0.25).map { $0 * 3600 }
    /// The furthest a proposal moves a parameter from its current value, as a share of it.
    public var maximumStep = 0.15
    /// The proposal must cut the held-out error by this share...
    public var minimumImprovement = 0.03
    /// ...with at least this many episodes behind it, fitted and held out.
    public var minimumCorrections = 8
    public var minimumValidationCorrections = 2
    public var minimumMeals = 5
    public var minimumValidationMeals = 2
    /// Hours (from, to) counted as morning when testing a separate sensitivity.
    public var morning = 5..<11

    public init() {}

    public static let `default` = CalibrationOptions()
}

/// Errors per horizon on the held-out or fitted stretch.
public struct CalibrationScore: Equatable, Sendable {
    public let errors: [Int: ForecastError]
    /// The mean of the horizons' mean absolute errors: what the fit minimises.
    public let meanAbsoluteError: Double
    public let episodes: Int

    init(_ forecasts: [ReplayedForecast], horizons: [Int], episodes: Int) {
        var byHorizon: [Int: [Double]] = [:]
        for forecast in forecasts {
            for (minute, error) in forecast.cleanErrors { byHorizon[minute, default: []].append(error) }
        }
        let errors = byHorizon.mapValues(ForecastError.init(errors:))
        self.errors = errors
        let maes = horizons.compactMap { errors[$0]?.meanAbsoluteError }
        meanAbsoluteError = maes.count == horizons.count ? maes.reduce(0, +) / Double(maes.count) : .nan
        self.episodes = episodes
    }
}

/// One fitted stage: the current and best values and how each scores, fitted and held out.
public struct CalibrationStage: Equatable, Sendable {
    public let current: TherapySettings
    /// The best fit over the whole search range.
    public let best: TherapySettings
    /// The best fit within `maximumStep` of the current values: what a proposal would apply.
    public let capped: TherapySettings
    public let fitted: [TherapySettings: CalibrationScore]
    public let heldOut: [TherapySettings: CalibrationScore]
    /// Quantities whose best value is at the end of the range searched: the truth may lie beyond.
    public let edges: Set<TherapyQuantity>

    public func fittedScore(_ therapy: TherapySettings) -> CalibrationScore? { fitted[therapy] }
    public func heldOutScore(_ therapy: TherapySettings) -> CalibrationScore? { heldOut[therapy] }
}

public struct MorningSensitivityTest: Equatable, Sendable {
    public let allDay: Double
    public let morning: Double
    /// Morning-forecast errors held out with the all-day and the morning sensitivity.
    public let allDayScore: CalibrationScore
    public let morningScore: CalibrationScore
    public let fittedEpisodes: Int
}

/// The average rate glucose drifts with no insulin or carbs acting, in mmol/L per hour.
public struct QuietDrift: Equatable, Sendable {
    public let night: Double?
    public let day: Double?
    public let nightHours: Double
    public let dayHours: Double
    public let episodes: Int
}

public struct CalibrationReport: Equatable, Sendable {
    public let computedAt: Date
    public let fittedRange: ClosedRange<Date>
    public let heldOutRange: ClosedRange<Date>
    public let insulin: CalibrationStage?
    public let carbs: CalibrationStage?
    public let morning: MorningSensitivityTest?
    public let drift: QuietDrift
    /// All held-out forecasts by time since the latest Bolus, with current and proposed settings.
    public let bolusAge: [TherapySettings: [BolusAge: [Int: ForecastError]]]
    public let proposal: CalibrationProposal?
}

/// A set of forecast settings to approve or reject together.
public struct CalibrationProposal: Equatable, Sendable, Codable {
    public struct Change: Equatable, Sendable, Codable {
        public let quantity: TherapyQuantity
        public let current: Double
        public let proposed: Double
    }

    public let computedAt: Date
    public let changes: [Change]
    public let current: TherapySettings
    public let proposed: TherapySettings
    /// The mean absolute error over the held-out stretch, current and proposed.
    public let heldOutError: Double
    public let proposedHeldOutError: Double
    public let corrections: Int
    public let meals: Int

    public var improvement: Double { heldOutError > 0 ? (heldOutError - proposedHeldOutError) / heldOutError : 0 }
}

/// The settings a calibration searches over: insulin curve and sensitivity, then carbs.
let calibratedQuantities: [TherapyQuantity] = [
    .insulinPeak, .insulinDuration, .insulinSensitivity, .carbRatio, .fastCarbAbsorption, .normalCarbAbsorption, .slowCarbAbsorption,
]

/// Fits the Forecast to History in stages. The insulin curve and sensitivity are fitted on
/// correction episodes alone; then, with those fixed, carb ratio and absorption times on meal
/// episodes. Older data is fitted and the most recent `validation` stretch held out to check it.
public func calibrateForecast(
    _ data: CalibrationData,
    therapy current: TherapySettings,
    excludedDays: [ExcludedDay],
    options: CalibrationOptions = .default,
    calendar: Calendar = .current
) -> CalibrationReport {
    let end = data.now.addingTimeInterval(-options.settleTime)
    let split = end.addingTimeInterval(-options.validation)
    let start = min(split, data.now.addingTimeInterval(-options.lookback))
    let timeline = data.timeline(therapy: current, excludedDays: excludedDays, calendar: calendar)
    let fittedTimes = replayTimes(data.readings, in: start...split, spacing: options.spacing)
    let heldOutTimes = replayTimes(data.readings, in: split...max(split, end), spacing: options.spacing)
    let drift = quietDrift(timeline, boluses: data.boluses, calendar: calendar)

    func times(_ times: [Date], _ kind: CalibrationEpisodeKind, hours: Range<Int>? = nil) -> [Date] {
        times.filter { date in
            timeline.label(at: date) == .episode(kind) && hours.map { $0.contains(calendar.component(.hour, from: date)) } ?? true
        }
    }

    func episodeCount(_ forecasts: [ReplayedForecast]) -> Int {
        let episodes = timeline.episodes
        return Set(forecasts.filter { !$0.cleanErrors.isEmpty }.compactMap { forecast in
            episodes.lastIndex { $0.start <= forecast.date }
        }).count
    }

    func score(_ therapy: TherapySettings, _ times: [Date]) -> CalibrationScore {
        let forecasts = replayForecasts(data, timeline: timeline, therapy: therapy, times: times)
        return CalibrationScore(forecasts, horizons: options.horizons, episodes: episodeCount(forecasts))
    }

    func withinStep(_ candidate: TherapySettings, _ quantities: [TherapyQuantity]) -> Bool {
        quantities.allSatisfy { quantity in
            guard let value = candidate[quantity], let base = current[quantity] else { return candidate[quantity] == current[quantity] }
            return abs(value - base) <= options.maximumStep * base + 1e-9
        }
    }

    func stage(_ candidates: [TherapySettings], from base: TherapySettings, fittedOn fitted: [Date], heldOut: [Date], _ quantities: [TherapyQuantity]) -> CalibrationStage? {
        guard !fitted.isEmpty else { return nil }
        let all = Array(Set(candidates + [base, current]))
        let scores = Dictionary(uniqueKeysWithValues: all.map { ($0, score($0, fitted)) })
        let ranked = all.filter { scores[$0]!.meanAbsoluteError.isFinite }.sorted { scores[$0]!.meanAbsoluteError < scores[$1]!.meanAbsoluteError }
        guard let best = ranked.first else { return nil }
        let capped = ranked.first { withinStep($0, quantities) } ?? base
        let keep = Array(Set([current, base, best, capped]))
        let edges = Set(quantities.filter { quantity in
            let values = candidates.compactMap { $0[quantity] }
            return best[quantity] == values.min() || best[quantity] == values.max()
        })
        return CalibrationStage(
            current: base,
            best: best,
            capped: capped,
            fitted: scores.filter { keep.contains($0.key) },
            heldOut: Dictionary(uniqueKeysWithValues: keep.map { ($0, score($0, heldOut)) }),
            edges: edges
        )
    }

    var insulinCandidates: [TherapySettings] = []
    for peak in options.peaks {
        for duration in options.durations where peak * 2 < duration {
            for sensitivity in options.sensitivities {
                var trial = current
                trial.insulinPeak = peak
                trial.insulinDuration = duration
                trial.insulinSensitivity = sensitivity
                insulinCandidates.append(trial)
            }
        }
    }
    let insulinQuantities: [TherapyQuantity] = [.insulinPeak, .insulinDuration, .insulinSensitivity]
    let insulin = stage(insulinCandidates, from: current, fittedOn: times(fittedTimes, .correction), heldOut: times(heldOutTimes, .correction), insulinQuantities)
    let insulinFit = insulin.flatMap { stage in
        let fitted = stage.fitted[stage.capped]?.episodes ?? 0
        let heldOut = stage.heldOut[stage.capped]?.episodes ?? 0
        return fitted >= options.minimumCorrections && heldOut >= options.minimumValidationCorrections ? stage.capped : nil
    } ?? current

    let mealFitted = times(fittedTimes, .meal)
    let mealHeldOut = times(heldOutTimes, .meal)
    var carbs: CalibrationStage?
    if let ratio = current.carbRatio {
        var candidates: [TherapySettings] = []
        for share in options.carbRatioShares {
            for absorption in options.absorptionTimes {
                var trial = insulinFit
                trial.carbRatio = (ratio * share * 2).rounded() / 2
                trial.carbAbsorptionTime = absorption
                trial.fastCarbAbsorptionTime = min(insulinFit.fastCarbAbsorptionTime, absorption)
                trial.slowCarbAbsorptionTime = max(insulinFit.slowCarbAbsorptionTime, absorption)
                if trial.isValid { candidates.append(trial) }
            }
        }
        carbs = stage(candidates, from: insulinFit, fittedOn: mealFitted, heldOut: mealHeldOut, [.carbRatio, .normalCarbAbsorption])
    }
    let carbFit = carbs.flatMap { stage in
        let fitted = stage.fitted[stage.capped]?.episodes ?? 0
        let heldOut = stage.heldOut[stage.capped]?.episodes ?? 0
        return fitted >= options.minimumMeals && heldOut >= options.minimumValidationMeals ? stage.capped : nil
    } ?? insulinFit

    let morning = morningSensitivity(
        base: insulinFit, options: options,
        fitted: times(fittedTimes, .correction, hours: options.morning),
        heldOut: times(heldOutTimes, .correction, hours: options.morning),
        score: score
    )

    let all = heldOutTimes
    let bolusAge = Dictionary(uniqueKeysWithValues: Array(Set([current, carbFit])).map { therapy in
        (therapy, BacktestResult(replayForecasts(data, timeline: timeline, therapy: therapy, times: all)).byBolusAge)
    })

    return CalibrationReport(
        computedAt: data.now,
        fittedRange: start...split,
        heldOutRange: split...max(split, end),
        insulin: insulin,
        carbs: carbs,
        morning: morning,
        drift: drift,
        bolusAge: bolusAge,
        proposal: proposal(now: data.now, current: current, proposed: carbFit, heldOut: heldOutTimes.filter { timeline.label(at: $0)?.episodeKind != .quiet }, insulin: insulin, carbs: carbs, options: options, score: score)
    )
}

private func proposal(
    now: Date,
    current: TherapySettings,
    proposed: TherapySettings,
    heldOut: [Date],
    insulin: CalibrationStage?,
    carbs: CalibrationStage?,
    options: CalibrationOptions,
    score: (TherapySettings, [Date]) -> CalibrationScore
) -> CalibrationProposal? {
    let changes = calibratedQuantities.compactMap { quantity -> CalibrationProposal.Change? in
        guard let from = current[quantity], let to = proposed[quantity], abs(from - to) > 1e-9 else { return nil }
        return CalibrationProposal.Change(quantity: quantity, current: from, proposed: to)
    }
    guard !changes.isEmpty else { return nil }
    let before = score(current, heldOut).meanAbsoluteError
    let after = score(proposed, heldOut).meanAbsoluteError
    guard before.isFinite, after.isFinite, after <= before * (1 - options.minimumImprovement) else { return nil }
    let insulinChanged = changes.contains { [.insulinPeak, .insulinDuration, .insulinSensitivity].contains($0.quantity) }
    let carbsChanged = changes.count > changes.filter { [.insulinPeak, .insulinDuration, .insulinSensitivity].contains($0.quantity) }.count
    return CalibrationProposal(
        computedAt: now,
        changes: changes,
        current: current,
        proposed: proposed,
        heldOutError: before,
        proposedHeldOutError: after,
        corrections: insulinChanged ? (insulin?.fitted[insulin!.capped]?.episodes ?? 0) : 0,
        meals: carbsChanged ? (carbs?.fitted[carbs!.capped]?.episodes ?? 0) : 0
    )
}

private func morningSensitivity(
    base: TherapySettings,
    options: CalibrationOptions,
    fitted: [Date],
    heldOut: [Date],
    score: (TherapySettings, [Date]) -> CalibrationScore
) -> MorningSensitivityTest? {
    guard !fitted.isEmpty, !heldOut.isEmpty, let allDay = base.insulinSensitivity else { return nil }
    let scored = options.sensitivities.map { sensitivity -> (Double, CalibrationScore) in
        var trial = base
        trial.insulinSensitivity = sensitivity
        return (sensitivity, score(trial, fitted))
    }.filter { $0.1.meanAbsoluteError.isFinite }
    guard let best = scored.min(by: { $0.1.meanAbsoluteError < $1.1.meanAbsoluteError }) else { return nil }
    var morning = base
    morning.insulinSensitivity = best.0
    return MorningSensitivityTest(
        allDay: allDay,
        morning: best.0,
        allDayScore: score(base, heldOut),
        morningScore: score(morning, heldOut),
        fittedEpisodes: best.1.episodes
    )
}

/// Least-squares slopes over quiet episodes at least an hour long, weighted by their length.
func quietDrift(_ timeline: CalibrationTimeline, boluses: [InsulinDose], calendar: Calendar) -> QuietDrift {
    var night: [(slope: Double, hours: Double)] = []
    var day: [(slope: Double, hours: Double)] = []
    for episode in timeline.episodes where episode.label == .episode(.quiet) {
        let hours = episode.end.timeIntervalSince(episode.start) / 3600
        guard hours >= 1 else { continue }
        let readings = timeline.readings.filter { $0.timestamp >= episode.start && $0.timestamp <= episode.end }
        let xs = readings.map { $0.timestamp.timeIntervalSince(episode.start) / 3600 }
        let ys = readings.map(\.value)
        let meanX = xs.reduce(0, +) / Double(xs.count)
        let meanY = ys.reduce(0, +) / Double(ys.count)
        let variance = xs.reduce(0) { $0 + ($1 - meanX) * ($1 - meanX) }
        guard variance > 0 else { continue }
        let slope = zip(xs, ys).reduce(0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) } / variance
        let midpoint = episode.start.addingTimeInterval(episode.end.timeIntervalSince(episode.start) / 2)
        if calendar.component(.hour, from: midpoint) < 6 { night.append((slope, hours)) } else { day.append((slope, hours)) }
    }
    func weighted(_ parts: [(slope: Double, hours: Double)]) -> Double? {
        let total = parts.reduce(0) { $0 + $1.hours }
        return total > 0 ? parts.reduce(0) { $0 + $1.slope * $1.hours } / total : nil
    }
    return QuietDrift(
        night: weighted(night),
        day: weighted(day),
        nightHours: night.reduce(0) { $0 + $1.hours },
        dayHours: day.reduce(0) { $0 + $1.hours },
        episodes: night.count + day.count
    )
}
