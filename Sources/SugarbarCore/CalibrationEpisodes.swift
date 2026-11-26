import Foundation

/// What was going on at a Reading, for calibrating the Forecast.
public enum CalibrationEpisodeKind: String, Sendable, CaseIterable, Codable {
    /// Up to 5 hours after a Bolus with no Meal from 3 hours before it until now.
    case correction
    /// After a Meal, or after a Bolus with a Meal near it.
    case meal
    /// No Bolus or Meal for at least 4 hours: overnight and other flat stretches.
    case quiet

    public var label: String {
        switch self {
        case .correction: "Correction"
        case .meal: "Meal"
        case .quiet: "Quiet"
        }
    }
}

public enum CalibrationExclusion: String, Sendable, CaseIterable, Codable {
    /// A day the owner marked: sick, exercise, alcohol, a sensor issue.
    case excludedDay
    /// Glucose rose more than insulin explains with no Meal logged: carbs nobody logged.
    case unloggedCarbs
}

public enum CalibrationLabel: Hashable, Sendable {
    case episode(CalibrationEpisodeKind)
    case excluded(CalibrationExclusion)

    public var episodeKind: CalibrationEpisodeKind? {
        if case let .episode(kind) = self { return kind }
        return nil
    }
}

/// A run of consecutive Readings with the same label.
public struct CalibrationEpisode: Equatable, Sendable {
    public let label: CalibrationLabel
    public let start: Date
    public let end: Date
    public let readingCount: Int
}

public struct CalibrationEpisodeRules: Equatable, Sendable {
    /// A Bolus or Meal keeps acting on the label this long.
    public var eventWindow: TimeInterval = 5 * 3600
    /// A Meal from this long before a Bolus to `mealAfterBolus` after it makes it a meal Bolus.
    public var mealBeforeBolus: TimeInterval = 3 * 3600
    public var mealAfterBolus: TimeInterval = 3600
    /// A rise is measured over this long.
    public var riseWindow: TimeInterval = 30 * 60
    /// A rise of at least this much, in mmol/L over `riseWindow`, and this much beyond what
    /// insulin explains, is carbs nobody logged. Requiring a real rise keeps an insulin curve
    /// that is simply too strong from reading as carbs.
    public var observedRise = 1.0
    public var unexplainedRise = 1.5
    /// From below the low threshold, a smaller rise is enough: a treated low.
    public var riseAfterLow = 0.5
    /// Flagged Readings this close together are one rise.
    public var riseRunGap: TimeInterval = 15 * 60
    /// Carbs keep acting this long after the rise they caused ends.
    public var unloggedCarbTail: TimeInterval = 2 * 3600
    /// A rise that a Bolus up to `correctionAfterRise` later stops within `riseAfterCorrection`
    /// is what the Bolus corrected, not carbs: only the rise itself is excluded.
    public var correctionAfterRise: TimeInterval = 30 * 60
    public var riseAfterCorrection: TimeInterval = 45 * 60

    public init() {}

    public static let `default` = CalibrationEpisodeRules()
}

/// Every Reading labelled, oldest first, with the runs they form.
public struct CalibrationTimeline: Sendable {
    public let readings: [Reading]
    public let labels: [CalibrationLabel]

    public var episodes: [CalibrationEpisode] {
        var runs: [CalibrationEpisode] = []
        var startIndex = 0
        for index in readings.indices where index == readings.count - 1 || labels[index + 1] != labels[index] {
            runs.append(CalibrationEpisode(
                label: labels[index],
                start: readings[startIndex].timestamp,
                end: readings[index].timestamp,
                readingCount: index - startIndex + 1
            ))
            startIndex = index + 1
        }
        return runs
    }

    /// The label of the latest Reading at or before `date`.
    public func label(at date: Date) -> CalibrationLabel? {
        let index = readings.partitioningIndex { $0.timestamp > date }
        return index > 0 ? labels[index - 1] : nil
    }

    /// Whether any Reading after `interval.lowerBound` up to its upper bound is excluded.
    func hasExclusion(in interval: ClosedRange<Date>) -> Bool {
        let start = readings.partitioningIndex { $0.timestamp >= interval.lowerBound }
        let end = readings.partitioningIndex { $0.timestamp > interval.upperBound }
        return labels[start..<max(start, end)].contains { $0.episodeKind == nil }
    }
}

/// Days the owner marked as not representative, as `yyyy-MM-dd` in the device's time zone.
public struct ExcludedDay: Equatable, Hashable, Sendable, Codable, Identifiable {
    public enum Reason: String, Sendable, Codable, CaseIterable {
        case sick, exercise, alcohol, sensor, other

        public var label: String {
            switch self {
            case .sick: "Sick"
            case .exercise: "Exercise"
            case .alcohol: "Alcohol"
            case .sensor: "Sensor issue"
            case .other: "Other"
            }
        }
    }

    public let day: String
    public let reason: Reason

    public var id: String { day }

    public init(day: String, reason: Reason) {
        self.day = day
        self.reason = reason
    }

    public init(date: Date, reason: Reason, calendar: Calendar) {
        self.init(day: dayKey(date, calendar: calendar), reason: reason)
    }

    public func date(calendar: Calendar) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// Sick 23–25 Nov 2026, marked before the owner could mark days themselves.
    public static let preMarked = ["2026-11-23", "2026-11-24", "2026-11-25"].map { ExcludedDay(day: $0, reason: .sick) }
}

func dayKey(_ date: Date, calendar: Calendar) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
}

/// Labels every Reading as a correction, meal or quiet episode, or excludes it: on a marked
/// day, or during a rise insulin does not explain while no Meal was logged, and for the carbs'
/// tail after it. The rise is judged against `therapy`'s insulin curve alone, so it only needs
/// to be roughly right.
public func labelCalibrationEpisodes(
    readings: [Reading],
    doses: [InsulinDose],
    meals: [Meal],
    therapy: TherapySettings,
    excludedDays: [ExcludedDay],
    thresholds: Thresholds = .standard,
    rules: CalibrationEpisodeRules = .default,
    calendar: Calendar = .current
) -> CalibrationTimeline {
    let readings = readings.filter { $0.outOfRange == nil }.sorted { $0.timestamp < $1.timestamp }
    let boluses = doses.filter { $0.kind == .bolus }.sorted { $0.timestamp < $1.timestamp }
    let meals = meals.filter(\.isEaten).sorted { $0.timestamp < $1.timestamp }
    let excluded = Set(excludedDays.map(\.day))

    func within<T>(_ items: [T], _ date: KeyPath<T, Date>, _ interval: ClosedRange<Date>) -> ArraySlice<T> {
        let start = items.partitioningIndex { $0[keyPath: date] >= interval.lowerBound }
        let end = items.partitioningIndex { $0[keyPath: date] > interval.upperBound }
        return items[start..<max(start, end)]
    }

    func context(at date: Date) -> CalibrationEpisodeKind {
        let recent = date.addingTimeInterval(-rules.eventWindow)...date
        if !within(meals, \.timestamp, recent).isEmpty { return .meal }
        let recentBoluses = within(boluses, \.timestamp, recent)
        guard !recentBoluses.isEmpty else { return .quiet }
        let mealBolus = recentBoluses.contains { bolus in
            let around = bolus.timestamp.addingTimeInterval(-rules.mealBeforeBolus)...bolus.timestamp.addingTimeInterval(rules.mealAfterBolus)
            return !within(meals, \.timestamp, around).isEmpty
        }
        return mealBolus ? .meal : .correction
    }

    let model = ExponentialInsulinModel(peak: therapy.insulinPeak, duration: therapy.insulinDuration)
    let sensitivity = therapy.insulinSensitivity ?? 3
    func insulinEffect(at date: Date) -> Double {
        within(boluses, \.timestamp, date.addingTimeInterval(-therapy.insulinDuration)...date).reduce(0) { total, dose in
            total - dose.units * sensitivity * (1 - model.remainingFraction(after: date.timeIntervalSince(dose.timestamp)))
        }
    }

    func isUnexplainedRise(at index: Int) -> Bool {
        let date = readings[index].timestamp
        let from = date.addingTimeInterval(-rules.riseWindow)
        guard let startValue = actualGlucose(at: from, sortedReadings: readings) else { return false }
        let observed = readings[index].value - startValue
        let unexplained = observed - (insulinEffect(at: date) - insulinEffect(at: from))
        if startValue < thresholds.low { return observed >= rules.riseAfterLow && unexplained >= rules.riseAfterLow }
        return observed >= rules.observedRise && unexplained >= rules.unexplainedRise
    }

    let contexts = readings.map { context(at: $0.timestamp) }
    var labels: [CalibrationLabel] = readings.indices.map { index in
        excluded.contains(dayKey(readings[index].timestamp, calendar: calendar)) ? .excluded(.excludedDay) : .episode(contexts[index])
    }

    let flagged = readings.indices.filter { index in
        contexts[index] != .meal && labels[index] != .excluded(.excludedDay) && isUnexplainedRise(at: index)
    }
    var runs: [(start: Date, end: Date)] = []
    for index in flagged {
        let date = readings[index].timestamp
        if let last = runs.last, date.timeIntervalSince(last.end) <= rules.riseRunGap {
            runs[runs.count - 1].end = date
        } else {
            runs.append((date.addingTimeInterval(-rules.riseWindow), date))
        }
    }
    for run in runs {
        let correctsIt = boluses.contains { bolus in
            bolus.timestamp >= run.start && bolus.timestamp <= run.end.addingTimeInterval(rules.correctionAfterRise)
                && run.end <= bolus.timestamp.addingTimeInterval(rules.riseAfterCorrection)
        }
        let until = correctsIt ? run.end : run.end.addingTimeInterval(rules.unloggedCarbTail)
        let first = readings.partitioningIndex { $0.timestamp >= run.start }
        let last = readings.partitioningIndex { $0.timestamp > until }
        for index in first..<max(first, last) where labels[index] != .excluded(.excludedDay) && contexts[index] != .meal {
            labels[index] = .excluded(.unloggedCarbs)
        }
    }

    return CalibrationTimeline(readings: readings, labels: labels)
}
