import Foundation

public struct ForecastLearningOptions: Equatable, Sendable {
    public var lookback: TimeInterval = 42 * 86400
    /// An event this old counts half as much as one from today.
    public var halfLife: TimeInterval = 14 * 86400
    /// Forecasts are replayed this often.
    public var sampleSpacing: TimeInterval = 10 * 60
    /// Recent hours are left out: Pen Doses reach History late.
    public var settleTime: TimeInterval = 12 * 3600
    /// The furthest a Suggestion moves a parameter from its current value, as a share of it.
    public var maximumStep = 0.2
    /// The candidate must cut the error by this share and this much in mmol/L...
    public var minimumImprovement = 0.04
    public var minimumAbsoluteImprovement = 0.05
    /// ...and do better in this (recency-weighted) share of the events.
    public var minimumWinShare = 0.6
    public var minimumCorrections = 8
    public var minimumMealsPerClass = 5
    public var minimumMeals = 8
    public var minimumTrendDays = 7
    public var minimumDays = 3
    /// Minutes ahead at which a replayed Forecast's error counts.
    public var horizons = [30, 60, 120]
    /// Only every this many replay times score the trend blend, which applies to all of them.
    public var trendBlendThinning = 3

    public init() {}

    public static let `default` = ForecastLearningOptions()
}

public let forecastLearningInterval: TimeInterval = 6 * 3600

public struct CandidateScore: Equatable, Sendable {
    public let value: Double
    /// Recency-weighted mean absolute error over the events, mmol/L.
    public let error: Double
}

/// What replaying the Forecast says about one parameter.
public struct ForecastParameterEstimate: Equatable, Sendable {
    public let quantity: TherapyQuantity
    public let current: Double
    public let best: Double
    public let currentError: Double
    public let bestError: Double
    /// Corrections, meals or days the replay drew on.
    public let eventCount: Int
    public let days: Int
    /// Recency-weighted share of events `best` predicted better than `current`.
    public let winShare: Double
    public let candidates: [CandidateScore]
    public let hasEnoughEvidence: Bool

    public var improvement: Double { currentError.isFinite && currentError > 0 ? (currentError - bestError) / currentError : 0 }
}

public struct ForecastLearning: Equatable, Sendable {
    public let computedAt: Date
    public let estimates: [ForecastParameterEstimate]
    public let suggestions: [TherapySuggestion]
    /// The Forecast replayed with the current settings over the last 14 days, for when the log is too young.
    public let replayScorecard: ForecastScorecard?

    public func estimate(_ quantity: TherapyQuantity) -> ForecastParameterEstimate? {
        estimates.first { $0.quantity == quantity }
    }

    func withSuggestions(_ visible: [TherapySuggestion]) -> ForecastLearning {
        ForecastLearning(computedAt: computedAt, estimates: estimates, suggestions: suggestions.filter { visible.contains($0) }, replayScorecard: replayScorecard)
    }
}

public func learnForecastParameters(history: HistoryStore, meals: [Meal], settings: Settings, now: Date = Date(), options: ForecastLearningOptions = .default) -> ForecastLearning {
    let span = now.addingTimeInterval(-options.lookback - replayContext)...now
    return learnForecastParameters(
        readings: history.readings(in: span),
        doses: history.doses(in: span),
        meals: meals.filter { span.contains($0.timestamp) },
        therapy: settings.therapy,
        thresholds: settings.thresholds,
        alerts: settings.alerts,
        now: now,
        options: options
    )
}

/// How far back a replayed Forecast looks for Doses and Meals still acting.
let replayContext: TimeInterval = 9 * 3600

/// Replays past Forecasts with candidate values of each forecast parameter and keeps what
/// predicts best, one parameter at a time with the others at their current values. A
/// candidate is never more than `maximumStep` from the current value, and becomes a
/// Suggestion only with enough independent events behind it and a clear, consistent win.
public func learnForecastParameters(
    readings: [Reading],
    doses: [InsulinDose],
    meals: [Meal],
    therapy: TherapySettings,
    thresholds: Thresholds,
    alerts: AlertSettings = .default,
    now: Date,
    options: ForecastLearningOptions = .default,
    calendar: Calendar = .current
) -> ForecastLearning {
    let replay = ForecastReplay(
        readings: readings.sorted { $0.timestamp < $1.timestamp },
        doses: doses.filter { $0.kind == .bolus }.sorted { $0.timestamp < $1.timestamp },
        meals: meals.filter(\.isEaten).sorted { $0.timestamp < $1.timestamp },
        thresholds: thresholds,
        now: now,
        options: options
    )
    guard therapy.isComplete, therapy.isValid, !replay.times.isEmpty else {
        return ForecastLearning(computedAt: now, estimates: [], suggestions: [], replayScorecard: nil)
    }
    let baseline = replay.baseline(therapy)
    let weight = { (date: Date) in pow(0.5, now.timeIntervalSince(date) / options.halfLife) }

    let corrections = estimateTherapy(
        readings: readings, doses: doses, meals: meals, therapy: therapy, thresholds: thresholds, now: now,
        options: { var o = TherapyEstimationOptions.default; o.lookback = options.lookback; o.settleTime = options.settleTime; return o }(),
        timeZone: calendar.timeZone
    ).sensitivity?.keptEpisodes ?? []
    let correctionEvents = corrections.map { episode in
        ReplayEvent(start: episode.start, times: replay.indices(in: episode.start...min(episode.end, episode.start.addingTimeInterval(4 * 3600))))
    }

    func mealEvents(_ speed: CarbAbsorption?) -> [ReplayEvent] {
        replay.meals.filter { meal in
            guard meal.carbsGrams >= 10, speed == nil || meal.carbAbsorption == speed else { return false }
            let window = therapy.absorptionTime(meal.carbAbsorption) * 1.25
            return !replay.meals.contains { other in
                other.id != meal.id && other.timestamp >= meal.timestamp.addingTimeInterval(-2 * 3600) && other.timestamp <= meal.timestamp.addingTimeInterval(window)
            }
        }.map { meal in
            ReplayEvent(start: meal.timestamp, times: replay.indices(in: meal.timestamp...meal.timestamp.addingTimeInterval(therapy.absorptionTime(meal.carbAbsorption) * 1.25)))
        }
    }

    func factorEvents(atBound bound: (ForecastLogEntry) -> Bool) -> [ReplayEvent] {
        mealEvents(nil).filter { event in event.times.contains { baseline[$0].map(bound) ?? false } }
    }

    let trendEvents: [ReplayEvent] = Dictionary(grouping: replay.times.indices.filter { $0 % options.trendBlendThinning == 0 }) {
        calendar.startOfDay(for: replay.times[$0])
    }
    .map { ReplayEvent(start: $0.key, times: $0.value) }
    .sorted { $0.start < $1.start }

    var estimates: [ForecastParameterEstimate] = []
    for quantity in TherapyQuantity.forecastParameters {
        let events: [ReplayEvent]
        let minimum: Int
        switch quantity {
        case .insulinPeak, .insulinDuration:
            events = correctionEvents
            minimum = options.minimumCorrections
        case .fastCarbAbsorption, .normalCarbAbsorption, .slowCarbAbsorption:
            events = mealEvents(quantity.carbAbsorption)
            minimum = options.minimumMealsPerClass
        case .trendBlend:
            events = trendEvents
            minimum = options.minimumTrendDays
        case .slowestCarbFactor:
            events = factorEvents { $0.carbFactor <= therapy.slowestCarbFactor + 1e-6 }
            minimum = options.minimumMeals
        case .fastestCarbFactor:
            events = factorEvents { $0.carbFactor >= therapy.fastestCarbFactor - 1e-6 }
            minimum = options.minimumMeals
        case .insulinSensitivity, .carbRatio:
            continue
        }
        let scored = events.filter { !$0.times.isEmpty }
        if let estimate = estimateParameter(
            quantity, therapy: therapy, events: scored, minimum: minimum,
            replay: replay, baseline: baseline, weight: weight, calendar: calendar, options: options
        ) {
            estimates.append(estimate)
        }
    }

    let suggestions = conservative(estimates.filter(\.hasEnoughEvidence)).map { estimate in
        TherapySuggestion(
            quantity: estimate.quantity,
            current: estimate.current,
            suggested: estimate.best,
            episodeCount: estimate.eventCount,
            days: estimate.days
        )
    }

    let recent = now.addingTimeInterval(-14 * 86400)
    let recentEntries = replay.times.indices.filter { replay.times[$0] >= recent }.compactMap { baseline[$0] }
    let scorecard = recentEntries.isEmpty ? nil : scoreForecasts(
        recentEntries, readings: replay.readings, rules: AlertScoringRules(alerts: alerts), now: now, calendar: calendar
    )
    return ForecastLearning(computedAt: now, estimates: estimates, suggestions: suggestions, replayScorecard: scorecard)
}

/// Insulin timing that is off also skews how meals seem to absorb, so while an insulin change is
/// pending no absorption change is offered, and only the insulin change that helps most.
func conservative(_ estimates: [ForecastParameterEstimate]) -> [ForecastParameterEstimate] {
    let insulin: Set<TherapyQuantity> = [.insulinPeak, .insulinDuration]
    guard let strongest = estimates.filter({ insulin.contains($0.quantity) }).max(by: { $0.improvement < $1.improvement }) else {
        return estimates
    }
    return estimates.filter { $0.quantity == strongest.quantity || ($0.quantity.carbAbsorption == nil && !insulin.contains($0.quantity)) }
}

struct ReplayEvent {
    let start: Date
    /// Indices into the replay's times.
    let times: [Int]
}

private func estimateParameter(
    _ quantity: TherapyQuantity,
    therapy: TherapySettings,
    events: [ReplayEvent],
    minimum: Int,
    replay: ForecastReplay,
    baseline: [ForecastLogEntry?],
    weight: (Date) -> Double,
    calendar: Calendar,
    options: ForecastLearningOptions
) -> ForecastParameterEstimate? {
    guard let current = therapy[quantity] else { return nil }
    let days = Set(events.map { calendar.startOfDay(for: $0.start) }).count
    let span = events.map(\.start).min().map { max(1, Int(ceil(replay.now.timeIntervalSince($0) / 86400))) } ?? 0
    guard !events.isEmpty else {
        return ForecastParameterEstimate(
            quantity: quantity, current: current, best: current, currentError: .nan, bestError: .nan,
            eventCount: 0, days: 0, winShare: 0, candidates: [], hasEnoughEvidence: false
        )
    }

    func eventErrors(_ entries: (Int) -> ForecastLogEntry?) -> [Double?] {
        events.map { event in
            let errors = event.times.compactMap { index in entries(index).flatMap { replay.error($0, horizons: options.horizons) } }
            return errors.isEmpty ? nil : errors.reduce(0, +) / Double(errors.count)
        }
    }

    let currentErrors = eventErrors { baseline[$0] }
    let usable = currentErrors.indices.filter { currentErrors[$0] != nil }
    guard !usable.isEmpty else { return nil }
    let weights = events.map { weight($0.start) }

    func score(_ errors: [Double?]) -> Double {
        let pairs = usable.compactMap { index in errors[index].map { ($0, weights[index]) } }
        let total = pairs.reduce(0) { $0 + $1.1 }
        return total > 0 ? pairs.reduce(0) { $0 + $1.0 * $1.1 } / total : .nan
    }

    let currentScore = score(currentErrors)
    var candidates = [CandidateScore(value: current, error: currentScore)]
    var candidateErrors: [Double: [Double?]] = [current: currentErrors]
    for value in candidateValues(quantity, current: current, therapy: therapy, maximumStep: options.maximumStep) {
        var trial = therapy
        trial[quantity] = value
        var cache: [Int: ForecastLogEntry?] = [:]
        let errors = eventErrors { index in
            if let cached = cache[index] { return cached }
            let entry = replay.entry(at: index, therapy: trial)
            cache[index] = entry
            return entry
        }
        candidateErrors[value] = errors
        candidates.append(CandidateScore(value: value, error: score(errors)))
    }
    candidates.sort { $0.value < $1.value }
    let best = candidates.filter(\.error.isFinite).min { $0.error < $1.error } ?? candidates[0]

    let bestErrors = candidateErrors[best.value] ?? currentErrors
    var wins = 0.0
    var decided = 0.0
    for index in usable {
        guard let now = currentErrors[index], let candidate = bestErrors[index], abs(now - candidate) > 0.005 else { continue }
        decided += weights[index]
        if candidate < now { wins += weights[index] }
    }
    let winShare = decided > 0 ? wins / decided : 0
    let improvement = currentScore - best.error
    let enough = best.value != current
        && usable.count >= minimum
        && days >= options.minimumDays
        && improvement >= options.minimumAbsoluteImprovement
        && improvement >= options.minimumImprovement * currentScore
        && winShare >= options.minimumWinShare
    return ForecastParameterEstimate(
        quantity: quantity,
        current: current,
        best: best.value,
        currentError: currentScore,
        bestError: best.error,
        eventCount: usable.count,
        days: span,
        winShare: winShare,
        candidates: candidates,
        hasEnoughEvidence: enough
    )
}

/// The settings' own step for each parameter, so a Suggestion is a value the user could have typed.
func parameterStep(_ quantity: TherapyQuantity) -> Double {
    switch quantity {
    case .insulinPeak, .trendBlend: 5 * 60
    case .insulinDuration, .fastCarbAbsorption, .normalCarbAbsorption, .slowCarbAbsorption: 15 * 60
    case .slowestCarbFactor, .fastestCarbFactor: 0.05
    case .insulinSensitivity: 0.1
    case .carbRatio: 0.5
    }
}

/// Values up to `maximumStep` either side of `current` in quarter steps, on the parameter's step and valid together with the other settings.
func candidateValues(_ quantity: TherapyQuantity, current: Double, therapy: TherapySettings, maximumStep: Double) -> [Double] {
    let step = parameterStep(quantity)
    let values = [-1.0, -0.75, -0.5, -0.25, 0.25, 0.5, 0.75, 1.0].map { fraction in
        ((current * (1 + fraction * maximumStep)) / step).rounded() * step
    }
    return Array(Set(values)).sorted().filter { value in
        guard abs(value - current) > step / 2, abs(value - current) <= maximumStep * current + 1e-9 else { return false }
        var trial = therapy
        trial[quantity] = value
        return trial.isValid
    }
}

/// In-range Readings in `interval`, at least `spacing` apart.
func replayTimes(_ readings: [Reading], in interval: ClosedRange<Date>, spacing: TimeInterval) -> [Date] {
    var times: [Date] = []
    for reading in readings where interval.contains(reading.timestamp) && reading.outOfRange == nil {
        if let last = times.last, reading.timestamp.timeIntervalSince(last) < spacing { continue }
        times.append(reading.timestamp)
    }
    return times
}

/// Past moments to replay the Forecast at, with what History knew then.
struct ForecastReplay {
    let readings: [Reading]
    let doses: [InsulinDose]
    let meals: [Meal]
    let thresholds: Thresholds
    let now: Date
    let times: [Date]

    init(readings: [Reading], doses: [InsulinDose], meals: [Meal], thresholds: Thresholds, now: Date, options: ForecastLearningOptions) {
        let from = now.addingTimeInterval(-options.lookback)
        let until = now.addingTimeInterval(-max(options.settleTime, 2 * 3600))
        self.init(
            readings: readings, doses: doses, meals: meals, thresholds: thresholds, now: now,
            times: replayTimes(readings, in: from...max(from, until), spacing: options.sampleSpacing)
        )
    }

    /// Expects `readings`, `doses` (Boluses) and eaten `meals` sorted by time.
    init(readings: [Reading], doses: [InsulinDose], meals: [Meal], thresholds: Thresholds, now: Date, times: [Date]) {
        self.readings = readings
        self.doses = doses
        self.meals = meals
        self.thresholds = thresholds
        self.now = now
        self.times = times
    }

    func indices(in interval: ClosedRange<Date>) -> [Int] {
        let start = times.partitioningIndex { $0 >= interval.lowerBound }
        let end = times.partitioningIndex { $0 > interval.upperBound }
        return Array(start..<max(start, end))
    }

    /// The Forecast at each replay time with `therapy`; nil where the Forecast could not be made.
    func baseline(_ therapy: TherapySettings) -> [ForecastLogEntry?] {
        times.indices.map { entry(at: $0, therapy: therapy) }
    }

    func entry(at index: Int, therapy: TherapySettings) -> ForecastLogEntry? {
        let t = times[index]
        let since = t.addingTimeInterval(-replayContext)
        let recentDoses = slice(doses, \.timestamp, since...t)
        let recentMeals = slice(meals, \.timestamp, since...t)
        guard let result = forecast(
            readings: Array(readingsSlice(readings, in: t.addingTimeInterval(-4 * momentumWindow)...t)),
            doses: recentDoses,
            meals: recentMeals,
            therapy: therapy,
            thresholds: thresholds,
            sensorActivation: nil,
            now: t
        ) else { return nil }
        return ForecastLogEntry(forecast: result, doses: recentDoses, meals: recentMeals, therapy: therapy, thresholds: thresholds)
    }

    /// Mean absolute error over the horizons that have a Reading.
    func error(_ entry: ForecastLogEntry, horizons: [Int]) -> Double? {
        let errors = horizons.compactMap { minute -> Double? in
            guard let predicted = entry.predicted(atMinute: minute) else { return nil }
            let target = entry.date.addingTimeInterval(Double(minute) * 60)
            guard target <= now, let actual = actualGlucose(at: target, sortedReadings: readings) else { return nil }
            return abs(predicted - actual)
        }
        return errors.isEmpty ? nil : errors.reduce(0, +) / Double(errors.count)
    }

    private func slice<T>(_ sorted: [T], _ date: KeyPath<T, Date>, _ interval: ClosedRange<Date>) -> [T] {
        let start = sorted.partitioningIndex { $0[keyPath: date] >= interval.lowerBound }
        let end = sorted.partitioningIndex { $0[keyPath: date] > interval.upperBound }
        return Array(sorted[start..<max(start, end)])
    }
}

/// The Forecast's track record and what replaying it suggests, recomputed every few hours.
public struct ForecastReview: Equatable, Sendable {
    public let computedAt: Date
    public let learning: ForecastLearning
    /// From this device's own log over the last 14 days.
    public let logged: ForecastScorecard?

    /// The logged record once it has a day's worth of scored Forecasts, else the replay with current settings.
    public var trackRecord: ForecastScorecard? {
        if let logged, logged.error(atMinute: 30).count >= minimumLoggedForTrackRecord { return logged }
        return learning.replayScorecard ?? logged
    }

    public var isReplayed: Bool { trackRecord != nil && trackRecord == learning.replayScorecard && trackRecord != logged }
}

public let minimumLoggedForTrackRecord = 200
public let trackRecordDays = 14

public func reviewForecasts(history: HistoryStore, meals: [Meal], settings: Settings, log: ForecastLogStore, now: Date = Date()) -> ForecastReview {
    let span = now.addingTimeInterval(-Double(trackRecordDays) * 86400)...now
    let entries = log.entries(in: span)
    let logged = entries.isEmpty ? nil : scoreForecasts(
        entries,
        readings: history.readings(in: span.lowerBound...now),
        rules: AlertScoringRules(alerts: settings.alerts),
        now: now
    )
    return ForecastReview(
        computedAt: now,
        learning: learnForecastParameters(history: history, meals: meals, settings: settings, now: now),
        logged: logged
    )
}
