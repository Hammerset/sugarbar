import Foundation

/// Loop's exponential insulin action curve: activity rises from zero, peaks at `peak`
/// and returns to zero at `duration`, with total area 1.
public struct ExponentialInsulinModel: Equatable, Sendable {
    public let peak: TimeInterval
    public let duration: TimeInterval
    private let tau: Double
    private let a: Double
    private let s: Double

    /// Requires `0 < peak < duration / 2`.
    public init(peak: TimeInterval, duration: TimeInterval) {
        precondition(peak > 0 && peak * 2 < duration, "insulin peak must be in the first half of the duration")
        self.peak = peak
        self.duration = duration
        tau = peak * (1 - peak / duration) / (1 - 2 * peak / duration)
        a = 2 * tau / duration
        s = 1 / (1 - a + (1 + a) * exp(-duration / tau))
    }

    /// Share of a dose still to act `elapsed` seconds after it was given: 1 at 0, 0 at `duration`.
    public func remainingFraction(after elapsed: TimeInterval) -> Double {
        if elapsed <= 0 { return 1 }
        if elapsed >= duration { return 0 }
        let t = elapsed
        return 1 - s * (1 - a) * ((t * t / (tau * duration * (1 - a)) - t / tau - 1) * exp(-t / tau) + 1)
    }

    /// Share of a dose acting per second at `elapsed`; the negative derivative of `remainingFraction`.
    public func activity(after elapsed: TimeInterval) -> Double {
        if elapsed <= 0 || elapsed >= duration { return 0 }
        let t = elapsed
        return s / (tau * tau) * t * (1 - t / duration) * exp(-t / tau)
    }
}

public struct ForecastPoint: Equatable, Sendable {
    public let date: Date
    public let value: Double
    /// The uncertainty range around `value`; equal to it at the latest Reading.
    public let lower: Double
    public let upper: Double

    public init(date: Date, value: Double, lower: Double? = nil, upper: Double? = nil) {
        self.date = date
        self.value = value
        self.lower = lower ?? value
        self.upper = upper ?? value
    }
}

public struct Forecast: Equatable, Sendable {
    /// Every 5 minutes from the latest Reading (its value, unchanged) until every Dose and
    /// Meal has finished acting, and at least `forecastDisplayHorizon` after the Reading.
    public let points: [ForecastPoint]
    /// Bolus units still to act at `now`.
    public let insulinOnBoard: Double
    /// Grams of logged carbs not yet absorbed at `now`.
    public let carbsOnBoard: Double
    /// First point that drops below `Thresholds.low` from at or above it.
    public let lowCrossing: Date?
    /// First point that rises above `Thresholds.high` from at or below it.
    public let highCrossing: Date?
    /// The CGM's rate of change over the last ~15 minutes, in mmol/L per minute; nil when the Readings can't tell.
    public let trendRate: Double?
    /// How much of `trendRate` insulin and carbs do not explain, in mmol/L per minute.
    public let unexplainedRate: Double?
    /// How fast the remaining carbs absorb from now, relative to the Meals' absorption times (1 = as logged).
    public let carbAbsorptionFactor: Double

    public init(
        points: [ForecastPoint],
        insulinOnBoard: Double,
        carbsOnBoard: Double,
        lowCrossing: Date?,
        highCrossing: Date?,
        trendRate: Double? = nil,
        unexplainedRate: Double? = nil,
        carbAbsorptionFactor: Double = 1
    ) {
        self.points = points
        self.insulinOnBoard = insulinOnBoard
        self.carbsOnBoard = carbsOnBoard
        self.lowCrossing = lowCrossing
        self.highCrossing = highCrossing
        self.trendRate = trendRate
        self.unexplainedRate = unexplainedRate
        self.carbAbsorptionFactor = carbAbsorptionFactor
    }

    /// Where glucose settles once every effect has finished.
    public var eventual: Double { points.last?.value ?? .nan }

    /// The CGM trend and the insulin-and-carbs model disagree by more than `forecastDisagreementMargin`.
    public var isUncertain: Bool { abs(unexplainedRate ?? 0) > forecastDisagreementMargin }

    /// The lowest forecast value within `window` of the latest Reading.
    public func lowestValue(within window: TimeInterval) -> Double? {
        guard let start = points.first?.date else { return nil }
        return points.filter { $0.date.timeIntervalSince(start) <= window }.map(\.value).min()
    }
}

public let forecastStep: TimeInterval = 5 * 60
/// How far ahead a chart shows the Forecast; also the shortest Forecast produced.
public let forecastDisplayHorizon: TimeInterval = 3 * 3600
/// The sensor's own reporting range; a Forecast outside it (or below zero) is not a meaningful number.
public let forecastValueRange = mmolPerL(fromMgPerDl: 40)...mmolPerL(fromMgPerDl: 500)
public let momentumWindow: TimeInterval = 15 * 60
/// About 1 mg/dL per minute: a gap between trend and model the Forecast calls uncertain.
public let forecastDisagreementMargin = 0.06
public let retrospectiveWindow: TimeInterval = 30 * 60
public let retrospectiveFadeDuration: TimeInterval = 60 * 60

/// Where glucose is heading, summing Bolus insulin, Meal carbs and recent momentum.
/// Nil when the therapy settings are incomplete or invalid, there is no fresh in-range
/// Reading, or the sensor is warming up. Informational; the Suggested Dose is calculated separately.
public func forecast(
    readings: [Reading],
    doses: [InsulinDose],
    meals: [Meal],
    therapy: TherapySettings,
    thresholds: Thresholds,
    sensorActivation: Date?,
    now: Date
) -> Forecast? {
    guard therapy.isValid,
          let sensitivity = therapy.insulinSensitivity,
          let carbRatio = therapy.carbRatio,
          let latest = readings.max(by: { $0.timestamp < $1.timestamp }),
          !latest.isStale(at: now),
          latest.outOfRange == nil,
          warmUpRemaining(activatedAt: sensorActivation, now: now) == nil
    else { return nil }

    let model = ExponentialInsulinModel(peak: therapy.insulinPeak, duration: therapy.insulinDuration)
    let boluses = doses.filter { $0.kind == .bolus && $0.timestamp <= now }
    let eaten = meals.filter { $0.isEaten && $0.timestamp <= now }
    let carbRise = sensitivity / carbRatio
    let anchor = latest.timestamp

    func carbsAbsorbed(_ meal: Meal, at date: Date) -> Double {
        meal.carbsAbsorbed(at: date, therapy: therapy)
    }

    func insulinEffect(at date: Date) -> Double {
        boluses.reduce(0) { total, dose in
            total - dose.units * sensitivity * (1 - model.remainingFraction(after: date.timeIntervalSince(dose.timestamp)))
        }
    }

    func carbEffect(at date: Date) -> Double {
        eaten.reduce(0) { $0 + carbsAbsorbed($1, at: date) * carbRise }
    }

    func modelled(at date: Date) -> Double { insulinEffect(at: date) + carbEffect(at: date) }

    let carbFactor = retrospectiveCarbFactor(
        readings: readings, latest: latest, modelled: modelled(at:), carbEffect: carbEffect(at:), range: therapy.carbFactorRange
    )
    /// Past the latest Reading the carbs' clock runs at `carbFactor`, easing back to real time.
    func carbClock(_ date: Date) -> Date {
        let ahead = date.timeIntervalSince(anchor)
        guard ahead > 0, carbFactor != 1 else { return date }
        let fade = retrospectiveFadeDuration
        let warped = ahead <= fade
            ? carbFactor * ahead + (1 - carbFactor) * ahead * ahead / (2 * fade)
            : ahead - (1 - carbFactor) * fade / 2
        return anchor.addingTimeInterval(warped)
    }

    func effect(at date: Date) -> Double { insulinEffect(at: date) + carbEffect(at: carbClock(date)) }

    let trend = cgmTrend(readings: readings, latest: latest, explained: modelled(at:))
    var momentum = trend?.unexplained ?? 0
    let carbRateNow = (carbEffect(at: anchor) - carbEffect(at: anchor.addingTimeInterval(-60))) / 60
    let correctionRate = (carbFactor - 1) * carbRateNow
    if momentum * correctionRate > 0 {
        momentum = momentum < 0 ? min(0, momentum - correctionRate) : max(0, momentum - correctionRate)
    }

    let carbDelay = max(0, (1 - carbFactor) * retrospectiveFadeDuration / 2)
    let effectsEnd = boluses.map { $0.timestamp.addingTimeInterval(therapy.insulinDuration) }
        + eaten.map { $0.timestamp.addingTimeInterval($0.absorptionTime(therapy) + carbDelay) }
    let horizon = max(forecastDisplayHorizon, (effectsEnd.max() ?? anchor).timeIntervalSince(anchor))
    let steps = Int((horizon / forecastStep).rounded(.up))
    let disagreement = abs(trend?.unexplained ?? 0) * 60
    var points = [ForecastPoint(date: anchor, value: latest.value)]
    var value = latest.value
    var previousEffect = effect(at: anchor)
    for step in 1...steps {
        let date = anchor.addingTimeInterval(Double(step) * forecastStep)
        let current = effect(at: date)
        value += current - previousEffect
        previousEffect = current
        let midpoint = (Double(step) - 0.5) * forecastStep
        value += max(0, 1 - midpoint / therapy.trendBlendDuration) * momentum * forecastStep
        let minutes = Double(step) * forecastStep / 60
        let spread = 0.25 + 0.01 * minutes + 0.5 * disagreement * min(minutes, 60)
        points.append(ForecastPoint(
            date: date,
            value: clampedToSensor(value),
            lower: clampedToSensor(value - spread),
            upper: clampedToSensor(value + spread)
        ))
    }

    return Forecast(
        points: points,
        insulinOnBoard: boluses.reduce(0) { $0 + $1.units * model.remainingFraction(after: now.timeIntervalSince($1.timestamp)) },
        carbsOnBoard: eaten.reduce(0) { $0 + $1.carbsGrams - carbsAbsorbed($1, at: now) },
        lowCrossing: firstCrossing(points) { $0 < thresholds.low },
        highCrossing: firstCrossing(points) { $0 > thresholds.high },
        trendRate: trend.map { $0.rate * 60 },
        unexplainedRate: trend.map { $0.unexplained * 60 },
        carbAbsorptionFactor: carbFactor
    )
}

private func clampedToSensor(_ value: Double) -> Double {
    min(max(value, forecastValueRange.lowerBound), forecastValueRange.upperBound)
}

private let momentumMinimumReadings = 3
private let momentumMinimumSpan: TimeInterval = 5 * 60
private let momentumMaximumGap: TimeInterval = 6 * 60
private let momentumMaximumSlope = 0.25 / 60
/// LibreLinkUp's graph has a point every 15 minutes, so a phone that just woke up has only those and the live Reading.
private let sparseTrendWindow: TimeInterval = 20 * 60
private let sparseTrendMaximumGap: TimeInterval = 16 * 60
private let retrospectiveReferenceTolerance: TimeInterval = 7.5 * 60
private let retrospectiveMinimumSpan: TimeInterval = 20 * 60
private let retrospectiveDeadband = 0.3
private let retrospectiveMinimumCarbEffect = 0.3

struct CGMTrend: Equatable {
    /// mmol/L per second.
    let rate: Double
    /// The part of `rate` that `explained` does not account for, in mmol/L per second.
    let unexplained: Double
}

/// The CGM's recent rate of change: a least-squares slope over the last 15 minutes of 1- or
/// 5-minute Readings; failing that, over the last 20 minutes of 15-minute graph points and the
/// live Reading; failing that, the live Reading's Trend arrow. Nil when none of those can tell
/// or the Readings include a LO/HI clamp. Both rates are capped against noise.
func cgmTrend(readings: [Reading], latest: Reading, explained: (Date) -> Double = { _ in 0 }) -> CGMTrend? {
    func fit(window: TimeInterval, minimumCount: Int, maximumGap: TimeInterval) -> CGMTrend? {
        let windowStart = latest.timestamp.addingTimeInterval(-window)
        let recent = readings
            .filter { $0.timestamp >= windowStart && $0.timestamp <= latest.timestamp }
            .sorted { $0.timestamp < $1.timestamp }
        guard recent.count >= minimumCount,
              let first = recent.first,
              latest.timestamp.timeIntervalSince(first.timestamp) >= momentumMinimumSpan,
              recent.allSatisfy({ $0.outOfRange == nil }),
              zip(recent, recent.dropFirst()).allSatisfy({ $1.timestamp.timeIntervalSince($0.timestamp) <= maximumGap }),
              let raw = slope(recent, latest: latest, explained: { _ in 0 }),
              let residual = slope(recent, latest: latest, explained: explained)
        else { return nil }
        return CGMTrend(rate: capped(raw), unexplained: capped(residual))
    }

    if let dense = fit(window: momentumWindow, minimumCount: momentumMinimumReadings, maximumGap: momentumMaximumGap) {
        return dense
    }
    let windowStart = latest.timestamp.addingTimeInterval(-sparseTrendWindow)
    if readings.contains(where: { $0.timestamp >= windowStart && $0.outOfRange != nil }) { return nil }
    if let sparse = fit(window: sparseTrendWindow, minimumCount: 2, maximumGap: sparseTrendMaximumGap) {
        return sparse
    }
    guard let arrow = latest.trend.typicalRate.map({ $0 / 60 }) else { return nil }
    let modelRate = (explained(latest.timestamp) - explained(latest.timestamp.addingTimeInterval(-momentumWindow))) / momentumWindow
    return CGMTrend(rate: arrow, unexplained: capped(arrow - modelRate))
}

private func capped(_ slope: Double) -> Double {
    min(max(slope, -momentumMaximumSlope), momentumMaximumSlope)
}

private func slope(_ readings: [Reading], latest: Reading, explained: (Date) -> Double) -> Double? {
    let xs = readings.map { $0.timestamp.timeIntervalSince(latest.timestamp) }
    let ys = readings.map { $0.value - explained($0.timestamp) }
    let meanX = xs.reduce(0, +) / Double(xs.count)
    let meanY = ys.reduce(0, +) / Double(ys.count)
    let covariance = zip(xs, ys).reduce(0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) }
    let variance = xs.reduce(0) { $0 + ($1 - meanX) * ($1 - meanX) }
    guard variance > 0 else { return nil }
    return covariance / variance
}

/// Retrospective correction: over the last 30 minutes, glucose changed by `actual` where the
/// model predicted `modelled`. With carbs absorbing, the miss is put down to them absorbing
/// slower (falling faster than predicted) or faster (rising faster), as a factor on the carbs'
/// absorption rate within `range`. 1 when there is no carb effect to adjust,
/// no Reading about 30 minutes back, or the miss is within the Readings' noise.
func retrospectiveCarbFactor(
    readings: [Reading],
    latest: Reading,
    modelled: (Date) -> Double,
    carbEffect: (Date) -> Double,
    range: ClosedRange<Double> = TherapySettings.default.carbFactorRange
) -> Double {
    let target = latest.timestamp.addingTimeInterval(-retrospectiveWindow)
    guard let reference = readings
        .filter({ abs($0.timestamp.timeIntervalSince(target)) <= retrospectiveReferenceTolerance && $0.outOfRange == nil })
        .min(by: { abs($0.timestamp.timeIntervalSince(target)) < abs($1.timestamp.timeIntervalSince(target)) }),
        latest.timestamp.timeIntervalSince(reference.timestamp) >= retrospectiveMinimumSpan
    else { return 1 }
    let carbsAbsorbing = carbEffect(latest.timestamp.addingTimeInterval(60)) > carbEffect(latest.timestamp)
    let carbWindow = carbEffect(latest.timestamp) - carbEffect(reference.timestamp)
    guard carbsAbsorbing, carbWindow >= retrospectiveMinimumCarbEffect else { return 1 }
    let miss = (latest.value - reference.value) - (modelled(latest.timestamp) - modelled(reference.timestamp))
    let beyondNoise = miss.sign == .minus ? min(0, miss + retrospectiveDeadband) : max(0, miss - retrospectiveDeadband)
    let factor = (carbWindow + beyondNoise) / carbWindow
    return min(max(factor, range.lowerBound), range.upperBound)
}

public extension Trend {
    /// The middle of the rate band each LibreLinkUp arrow stands for, in mmol/L per minute.
    var typicalRate: Double? {
        switch self {
        case .notDetermined: nil
        case .fallingQuickly: -mmolPerL(fromMgPerDl: 2.5)
        case .falling: -mmolPerL(fromMgPerDl: 1.5)
        case .stable: 0
        case .rising: mmolPerL(fromMgPerDl: 1.5)
        case .risingQuickly: mmolPerL(fromMgPerDl: 2.5)
        }
    }
}

private func firstCrossing(_ points: [ForecastPoint], beyond: (Double) -> Bool) -> Date? {
    zip(points, points.dropFirst())
        .first { !beyond($0.0.value) && beyond($0.1.value) }?
        .1.date
}

public extension Forecast {
    /// The stretch a chart draws: up to `forecastDisplayHorizon` after the latest Reading.
    var displayPoints: [ForecastPoint] {
        guard let start = points.first?.date else { return [] }
        return points.filter { $0.date.timeIntervalSince(start) <= forecastDisplayHorizon }
    }
}

/// The Forecast from History, looking back as far as any Dose or Meal can still act.
public func forecastFromHistory(
    _ history: HistoryStore,
    meals: [Meal],
    sensorActivation: Date?,
    settings: Settings,
    now: Date
) -> Forecast? {
    let therapy = settings.therapy
    let since = now.addingTimeInterval(-max(therapy.insulinDuration, therapy.slowCarbAbsorptionTime))
    return forecast(
        readings: history.readings(in: now.addingTimeInterval(-4 * momentumWindow)...now),
        doses: history.doses(in: since...now),
        meals: meals.filter { $0.timestamp >= since },
        therapy: therapy,
        thresholds: settings.thresholds,
        sensorActivation: sensorActivation,
        now: now
    )
}
