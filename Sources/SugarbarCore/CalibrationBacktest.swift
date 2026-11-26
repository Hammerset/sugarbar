import Foundation

/// History to replay the Forecast over: Readings, Boluses and eaten Meals, oldest first.
public struct CalibrationData: Sendable {
    public let readings: [Reading]
    public let boluses: [InsulinDose]
    public let meals: [Meal]
    public let thresholds: Thresholds
    /// Nothing after this is known.
    public let now: Date

    public init(readings: [Reading], doses: [InsulinDose], meals: [Meal], thresholds: Thresholds, now: Date) {
        self.readings = readings.sorted { $0.timestamp < $1.timestamp }
        boluses = doses.filter { $0.kind == .bolus }.sorted { $0.timestamp < $1.timestamp }
        self.meals = meals.filter(\.isEaten).sorted { $0.timestamp < $1.timestamp }
        self.thresholds = thresholds
        self.now = now
    }

    public init(history: HistoryStore, meals: [Meal], thresholds: Thresholds, lookback: TimeInterval, now: Date) {
        let span = now.addingTimeInterval(-lookback - replayContext)...now
        self.init(
            readings: history.readings(in: span),
            doses: history.doses(in: span),
            meals: meals.filter { span.contains($0.timestamp) },
            thresholds: thresholds,
            now: now
        )
    }

    /// A Bolus or Meal the Forecast at `date` could not know about acts before `until`.
    func hasEvent(after date: Date, until: Date) -> Bool {
        let bolus = boluses.partitioningIndex { $0.timestamp > date }
        if bolus < boluses.count, boluses[bolus].timestamp <= until { return true }
        let meal = meals.partitioningIndex { $0.timestamp > date }
        return meal < meals.count && meals[meal].timestamp <= until
    }

    func timeline(therapy: TherapySettings, excludedDays: [ExcludedDay], calendar: Calendar) -> CalibrationTimeline {
        labelCalibrationEpisodes(
            readings: readings, doses: boluses, meals: meals, therapy: therapy,
            excludedDays: excludedDays, thresholds: thresholds, calendar: calendar
        )
    }
}

/// How long before a Forecast the latest Bolus was: a sensitivity error biases every group the
/// same way, while a timing error reads high in the first hour and low after.
public enum BolusAge: Int, Sendable, CaseIterable, Comparable {
    case underOneHour, oneToTwoHours, twoToThreeHours, threeToFiveHours

    init?(elapsed: TimeInterval) {
        switch elapsed {
        case 0..<3600: self = .underOneHour
        case 3600..<7200: self = .oneToTwoHours
        case 7200..<10800: self = .twoToThreeHours
        case 10800...18000: self = .threeToFiveHours
        default: return nil
        }
    }

    public var label: String {
        switch self {
        case .underOneHour: "0–1 h"
        case .oneToTwoHours: "1–2 h"
        case .twoToThreeHours: "2–3 h"
        case .threeToFiveHours: "3–5 h"
        }
    }

    public static func < (lhs: BolusAge, rhs: BolusAge) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One replayed Forecast's errors (predicted minus actual) per horizon.
struct ReplayedForecast: Sendable {
    let date: Date
    let label: CalibrationLabel?
    let bolusAge: BolusAge?
    /// Every horizon with a Reading to score against.
    let errors: [Int: Double]
    /// Only horizons with no excluded Reading and no new Bolus or Meal since the Forecast, when it is not excluded itself.
    let cleanErrors: [Int: Double]
}

public struct BacktestResult: Equatable, Sendable {
    public let forecastCount: Int
    /// Every replayed Forecast, excluded or not: what the app's own replay reports.
    public let all: [Int: ForecastError]
    /// Forecasts with no excluded Reading and no new Bolus or Meal from when they were made to the horizon.
    public let included: [Int: ForecastError]
    public let byEpisode: [CalibrationEpisodeKind: [Int: ForecastError]]
    public let byBolusAge: [BolusAge: [Int: ForecastError]]

    init(_ forecasts: [ReplayedForecast]) {
        func errors(_ forecasts: [ReplayedForecast], _ values: (ReplayedForecast) -> [Int: Double]) -> [Int: ForecastError] {
            var byHorizon: [Int: [Double]] = [:]
            for forecast in forecasts {
                for (minute, error) in values(forecast) { byHorizon[minute, default: []].append(error) }
            }
            return byHorizon.mapValues(ForecastError.init(errors:))
        }
        forecastCount = forecasts.count
        all = errors(forecasts, \.errors)
        included = errors(forecasts, \.cleanErrors)
        byEpisode = Dictionary(grouping: forecasts.filter { $0.label?.episodeKind != nil }) { $0.label!.episodeKind! }
            .mapValues { errors($0, \.cleanErrors) }
        byBolusAge = Dictionary(grouping: forecasts.filter { $0.bolusAge != nil }) { $0.bolusAge! }
            .mapValues { errors($0, \.cleanErrors) }
    }
}

/// Replays the Forecast at `times` with `therapy`, each from only the Readings, Boluses and Meals
/// timed before it, and scores it against the Readings that followed.
func replayForecasts(
    _ data: CalibrationData,
    timeline: CalibrationTimeline,
    therapy: TherapySettings,
    times: [Date],
    horizons: [Int] = forecastScoreHorizons
) -> [ReplayedForecast] {
    let replay = ForecastReplay(
        readings: data.readings, doses: data.boluses, meals: data.meals,
        thresholds: data.thresholds, now: data.now, times: times
    )
    return concurrentMap(Array(times.indices)) { index -> ReplayedForecast? in
        guard let entry = replay.entry(at: index, therapy: therapy) else { return nil }
        let date = times[index]
        let label = timeline.label(at: date)
        var errors: [Int: Double] = [:]
        var clean: [Int: Double] = [:]
        for minute in horizons {
            let target = date.addingTimeInterval(Double(minute) * 60)
            guard target <= data.now,
                  let predicted = entry.predicted(atMinute: minute),
                  let actual = actualGlucose(at: target, sortedReadings: data.readings)
            else { continue }
            errors[minute] = predicted - actual
            if label?.episodeKind != nil, !timeline.hasExclusion(in: date...target), !data.hasEvent(after: date, until: target) {
                clean[minute] = predicted - actual
            }
        }
        let bolusIndex = data.boluses.partitioningIndex { $0.timestamp > date }
        let lastBolus = bolusIndex > 0 ? data.boluses[bolusIndex - 1] : nil
        return ReplayedForecast(
            date: date,
            label: label,
            bolusAge: lastBolus.flatMap { BolusAge(elapsed: date.timeIntervalSince($0.timestamp)) },
            errors: errors,
            cleanErrors: clean
        )
    }.compactMap(\.self)
}

/// Replays the Forecast with `therapy` at Readings in `interval`, at least `spacing` apart (every
/// Reading at 0), and reports its errors overall, per episode kind and by time since the last Bolus.
public func backtestForecast(
    _ data: CalibrationData,
    therapy: TherapySettings,
    excludedDays: [ExcludedDay],
    interval: ClosedRange<Date>,
    spacing: TimeInterval = 0,
    calendar: Calendar = .current
) -> BacktestResult {
    let timeline = data.timeline(therapy: therapy, excludedDays: excludedDays, calendar: calendar)
    let times = replayTimes(data.readings, in: interval, spacing: spacing)
    return BacktestResult(replayForecasts(data, timeline: timeline, therapy: therapy, times: times))
}

func concurrentMap<T: Sendable, U: Sendable>(_ items: [T], _ transform: @Sendable (T) -> U) -> [U] {
    let chunks = max(1, min(items.count, ProcessInfo.processInfo.activeProcessorCount * 4))
    let results = ConcurrentResults<U>(count: items.count)
    DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
        var index = chunk
        while index < items.count {
            results.set(transform(items[index]), at: index)
            index += chunks
        }
    }
    return results.values
}

private final class ConcurrentResults<U>: @unchecked Sendable {
    private var storage: [U?]
    private let lock = NSLock()

    init(count: Int) { storage = Array(repeating: nil, count: count) }

    func set(_ value: U, at index: Int) { lock.withLock { storage[index] = value } }

    var values: [U] { lock.withLock { storage.map { $0! } } }
}
