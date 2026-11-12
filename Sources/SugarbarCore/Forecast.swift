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

    /// Where glucose settles once every effect has finished.
    public var eventual: Double { points.last?.value ?? .nan }
}

public let forecastStep: TimeInterval = 5 * 60
/// How far ahead a chart shows the Forecast; also the shortest Forecast produced.
public let forecastDisplayHorizon: TimeInterval = 3 * 3600
public let momentumWindow: TimeInterval = 15 * 60
public let momentumBlendDuration: TimeInterval = 30 * 60

/// Where glucose is heading, summing Bolus insulin, Meal carbs and recent momentum.
/// Nil when the therapy settings are incomplete or invalid, there is no fresh in-range
/// Reading, or the sensor is warming up. Informational only: never a dose recommendation.
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
    let eaten = meals.filter { $0.timestamp <= now }
    let carbRise = sensitivity / carbRatio

    func carbsAbsorbed(_ meal: Meal, at date: Date) -> Double {
        let elapsed = date.timeIntervalSince(meal.timestamp)
        return meal.carbsGrams * min(max(elapsed / therapy.carbAbsorptionTime, 0), 1)
    }

    func cumulativeEffect(at date: Date) -> Double {
        let insulin = boluses.reduce(0) { total, dose in
            total - dose.units * sensitivity * (1 - model.remainingFraction(after: date.timeIntervalSince(dose.timestamp)))
        }
        let carbs = eaten.reduce(0) { $0 + carbsAbsorbed($1, at: date) * carbRise }
        return insulin + carbs
    }

    let slope = momentumSlope(readings: readings, latest: latest)
    let effectsEnd = boluses.map { $0.timestamp.addingTimeInterval(therapy.insulinDuration) }
        + eaten.map { $0.timestamp.addingTimeInterval(therapy.carbAbsorptionTime) }
    let horizon = max(forecastDisplayHorizon, (effectsEnd.max() ?? latest.timestamp).timeIntervalSince(latest.timestamp))
    let steps = Int((horizon / forecastStep).rounded(.up))
    var points = [ForecastPoint(date: latest.timestamp, value: latest.value)]
    var value = latest.value
    var previousEffect = cumulativeEffect(at: latest.timestamp)
    for step in 1...steps {
        let date = latest.timestamp.addingTimeInterval(Double(step) * forecastStep)
        let effect = cumulativeEffect(at: date)
        let effectDelta = effect - previousEffect
        previousEffect = effect
        // Momentum already reflects what insulin and carbs are doing right now, so it
        // replaces their effect at first and hands over to it as its weight fades.
        if let slope {
            let midpoint = (Double(step) - 0.5) * forecastStep
            let weight = max(0, 1 - midpoint / momentumBlendDuration)
            value += weight * slope * forecastStep + (1 - weight) * effectDelta
        } else {
            value += effectDelta
        }
        points.append(ForecastPoint(date: date, value: value))
    }

    return Forecast(
        points: points,
        insulinOnBoard: boluses.reduce(0) { $0 + $1.units * model.remainingFraction(after: now.timeIntervalSince($1.timestamp)) },
        carbsOnBoard: eaten.reduce(0) { $0 + $1.carbsGrams - carbsAbsorbed($1, at: now) },
        lowCrossing: firstCrossing(points) { $0 < thresholds.low },
        highCrossing: firstCrossing(points) { $0 > thresholds.high }
    )
}

private let momentumMinimumReadings = 3
private let momentumMinimumSpan: TimeInterval = 5 * 60
private let momentumMaximumGap: TimeInterval = 6 * 60
private let momentumMaximumSlope = 0.25 / 60

/// Least-squares slope in mmol/L per second over the last 15 minutes, or nil when the
/// Readings are too few, too short a span, gapped, or include a LO/HI clamp.
func momentumSlope(readings: [Reading], latest: Reading) -> Double? {
    let windowStart = latest.timestamp.addingTimeInterval(-momentumWindow)
    let recent = readings
        .filter { $0.timestamp >= windowStart && $0.timestamp <= latest.timestamp }
        .sorted { $0.timestamp < $1.timestamp }
    guard recent.count >= momentumMinimumReadings,
          let first = recent.first,
          latest.timestamp.timeIntervalSince(first.timestamp) >= momentumMinimumSpan,
          recent.allSatisfy({ $0.outOfRange == nil })
    else { return nil }
    for (earlier, later) in zip(recent, recent.dropFirst())
    where later.timestamp.timeIntervalSince(earlier.timestamp) > momentumMaximumGap {
        return nil
    }

    let xs = recent.map { $0.timestamp.timeIntervalSince(latest.timestamp) }
    let ys = recent.map(\.value)
    let meanX = xs.reduce(0, +) / Double(xs.count)
    let meanY = ys.reduce(0, +) / Double(ys.count)
    let covariance = zip(xs, ys).reduce(0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) }
    let variance = xs.reduce(0) { $0 + ($1 - meanX) * ($1 - meanX) }
    guard variance > 0 else { return nil }
    return min(max(covariance / variance, -momentumMaximumSlope), momentumMaximumSlope)
}

private func firstCrossing(_ points: [ForecastPoint], beyond: (Double) -> Bool) -> Date? {
    zip(points, points.dropFirst())
        .first { !beyond($0.0.value) && beyond($0.1.value) }?
        .1.date
}
