import Foundation

public enum AlertLevel: String, Codable, CaseIterable, Sendable {
    case urgentLow
    case low
    case high
    case urgentHigh

    public var label: String {
        switch self {
        case .urgentLow: "Urgent low"
        case .low: "Low"
        case .high: "High"
        case .urgentHigh: "Urgent high"
        }
    }

    public var isLow: Bool { self == .low || self == .urgentLow }
    public var isUrgent: Bool { self == .urgentLow || self == .urgentHigh }
}

public struct AlertSettings: Equatable, Sendable, Codable {
    public var isEnabled: Bool
    public var enabledLevels: Set<AlertLevel>
    public var lowRepeatInterval: TimeInterval
    public var highRepeatInterval: TimeInterval
    public var snoozedUntil: Date?
    public var predictsLow: Bool
    /// How far ahead a Forecast crossing of the low threshold warns.
    public var predictedLowLead: TimeInterval
    public var predictsHigh: Bool
    public var predictedHighLead: TimeInterval

    public init(
        isEnabled: Bool,
        enabledLevels: Set<AlertLevel>,
        lowRepeatInterval: TimeInterval,
        highRepeatInterval: TimeInterval,
        snoozedUntil: Date? = nil,
        predictsLow: Bool = true,
        predictedLowLead: TimeInterval = 30 * 60,
        predictsHigh: Bool = false,
        predictedHighLead: TimeInterval = 60 * 60
    ) {
        self.isEnabled = isEnabled
        self.enabledLevels = enabledLevels
        self.lowRepeatInterval = lowRepeatInterval
        self.highRepeatInterval = highRepeatInterval
        self.snoozedUntil = snoozedUntil
        self.predictsLow = predictsLow
        self.predictedLowLead = predictedLowLead
        self.predictsHigh = predictsHigh
        self.predictedHighLead = predictedHighLead
    }

    public static let `default` = AlertSettings(
        isEnabled: false,
        enabledLevels: [.urgentLow, .low],
        lowRepeatInterval: 20 * 60,
        highRepeatInterval: 60 * 60
    )

    public static let repeatIntervalRange: ClosedRange<TimeInterval> = (5 * 60)...(4 * 60 * 60)
    public static let predictionLeadRange: ClosedRange<TimeInterval> = (10 * 60)...(120 * 60)

    public func isSnoozed(at now: Date) -> Bool {
        guard let snoozedUntil else { return false }
        return now < snoozedUntil
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, enabledLevels, lowRepeatInterval, highRepeatInterval, snoozedUntil
        case predictsLow, predictedLowLead, predictsHigh, predictedHighLead
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AlertSettings.default
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? fallback.isEnabled
        enabledLevels = try container.decodeIfPresent(Set<AlertLevel>.self, forKey: .enabledLevels) ?? fallback.enabledLevels
        lowRepeatInterval = Self.clamped(try container.decodeIfPresent(TimeInterval.self, forKey: .lowRepeatInterval) ?? fallback.lowRepeatInterval)
        highRepeatInterval = Self.clamped(try container.decodeIfPresent(TimeInterval.self, forKey: .highRepeatInterval) ?? fallback.highRepeatInterval)
        snoozedUntil = try container.decodeIfPresent(Date.self, forKey: .snoozedUntil)
        predictsLow = try container.decodeIfPresent(Bool.self, forKey: .predictsLow) ?? fallback.predictsLow
        predictedLowLead = Self.clamped(
            try container.decodeIfPresent(TimeInterval.self, forKey: .predictedLowLead) ?? fallback.predictedLowLead,
            to: Self.predictionLeadRange
        )
        predictsHigh = try container.decodeIfPresent(Bool.self, forKey: .predictsHigh) ?? fallback.predictsHigh
        predictedHighLead = Self.clamped(
            try container.decodeIfPresent(TimeInterval.self, forKey: .predictedHighLead) ?? fallback.predictedHighLead,
            to: Self.predictionLeadRange
        )
    }

    private static func clamped(_ interval: TimeInterval, to range: ClosedRange<TimeInterval> = repeatIntervalRange) -> TimeInterval {
        min(max(interval, range.lowerBound), range.upperBound)
    }
}

/// One thing that may warrant a notification right now. Conditions sharing a `family`
/// debounce together; a higher `rank` within the family is an escalation.
public struct AlertCondition: Equatable, Sendable {
    public let family: String
    public let rank: Int
    public let repeatInterval: TimeInterval
    public let title: String
    public let repeatTitle: String
    public let body: String
    public let isUrgent: Bool

    public init(
        family: String,
        rank: Int,
        repeatInterval: TimeInterval,
        title: String,
        repeatTitle: String,
        body: String,
        isUrgent: Bool
    ) {
        self.family = family
        self.rank = rank
        self.repeatInterval = repeatInterval
        self.title = title
        self.repeatTitle = repeatTitle
        self.body = body
        self.isUrgent = isUrgent
    }
}

public struct AlertState: Equatable, Sendable, Codable {
    public struct Entry: Equatable, Sendable, Codable {
        public let rank: Int
        public let lastAlertAt: Date

        public init(rank: Int, lastAlertAt: Date) {
            self.rank = rank
            self.lastAlertAt = lastAlertAt
        }
    }

    public var entries: [String: Entry]

    public init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }
}

public struct AlertNotification: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case entered
        case escalated
        case repeated
    }

    public let family: String
    public let reason: Reason
    public let title: String
    public let body: String
    public let isUrgent: Bool
}

public struct AlertDecision: Equatable, Sendable {
    public let notifications: [AlertNotification]
    /// Families that were alerting and no longer apply, so their delivered notifications can be withdrawn.
    public let resolvedFamilies: [String]
    public let state: AlertState
}

/// Pass `nil` conditions when the data can't be judged (stale, warm-up): state is held
/// rather than reset, so a gap in data neither alerts nor counts as a return to range.
public func evaluateAlerts(
    conditions: [AlertCondition]?,
    state: AlertState,
    now: Date,
    snoozedUntil: Date? = nil
) -> AlertDecision {
    guard let conditions else {
        return AlertDecision(notifications: [], resolvedFamilies: [], state: state)
    }
    let snoozed = snoozedUntil.map { now < $0 } ?? false
    var next = AlertState()
    var notifications: [AlertNotification] = []

    let strongest = Dictionary(grouping: conditions, by: \.family)
        .compactMapValues { $0.max { $0.rank < $1.rank } }

    for (family, condition) in strongest.sorted(by: { $0.key < $1.key }) {
        let previous = state.entries[family]
        let reason: AlertNotification.Reason?
        if let previous {
            if condition.rank > previous.rank {
                reason = .escalated
            } else if now.timeIntervalSince(previous.lastAlertAt) >= condition.repeatInterval {
                reason = .repeated
            } else {
                reason = nil
            }
        } else {
            reason = .entered
        }

        if let reason, !snoozed {
            notifications.append(AlertNotification(
                family: family,
                reason: reason,
                title: reason == .repeated ? condition.repeatTitle : condition.title,
                body: condition.body,
                isUrgent: condition.isUrgent
            ))
            next.entries[family] = .init(rank: condition.rank, lastAlertAt: now)
        } else if let previous {
            next.entries[family] = previous
        }
    }

    let resolved = state.entries.keys.filter { strongest[$0] == nil }.sorted()
    return AlertDecision(notifications: notifications, resolvedFamilies: resolved, state: next)
}

public enum GlucoseAlertFamily {
    public static let low = "glucose.low"
    public static let high = "glucose.high"
}

/// Conditions for the latest Reading's Band. `nil` when there's no live Reading to judge.
/// A disabled urgent level falls back to its non-urgent sibling, never the reverse.
public func glucoseAlertConditions(
    latest: Reading?,
    sensorActivation: Date?,
    now: Date,
    thresholds: Thresholds,
    settings: AlertSettings
) -> [AlertCondition]? {
    guard settings.isEnabled else { return [] }
    guard case let .live(value, band, trend, outOfRange) = barContent(
        latest: latest, sensorActivation: sensorActivation, now: now, thresholds: thresholds
    ), let latest else { return nil }

    let candidates: [AlertLevel]
    switch band {
    case .urgentLow: candidates = [.urgentLow, .low]
    case .low: candidates = [.low]
    case .inRange: candidates = []
    case .high: candidates = [.high]
    case .urgentHigh: candidates = [.urgentHigh, .high]
    }
    guard let level = candidates.first(where: settings.enabledLevels.contains) else { return [] }

    let valueText = outOfRange?.label ?? formatMmolPerL(value)
    let reading = [valueText, trend.arrowText].compactMap { $0 }.joined(separator: " ")
    let direction = level.isLow ? "low" : "high"
    return [AlertCondition(
        family: level.isLow ? GlucoseAlertFamily.low : GlucoseAlertFamily.high,
        rank: level.isUrgent ? 1 : 0,
        repeatInterval: level.isLow ? settings.lowRepeatInterval : settings.highRepeatInterval,
        title: "\(level.label): \(reading)",
        repeatTitle: "Still \(level.isUrgent ? "urgent \(direction)" : direction): \(reading)",
        body: "\(valueText) mmol/L, Reading \(formatAge(latest.age(at: now))). Check with your sensor app or meter. Sugarbar is not a medical device.",
        isUrgent: level.isUrgent
    )]
}

public enum ForecastAlertFamily {
    public static let low = "forecast.low"
    public static let high = "forecast.high"
}

/// Early warnings when the Forecast crosses the low threshold within `predictedLowLead`
/// or the high threshold within `predictedHighLead`. Quiet while the latest Reading is
/// already past that threshold, since the glucose alert covers it. `alerting` holds the
/// families already warned about: those stay on while the crossing is within twice the
/// lead, so a crossing hovering at the edge of the window does not re-alert every poll.
public func forecastAlertConditions(
    forecast: Forecast?,
    latest: Reading?,
    now: Date,
    thresholds: Thresholds,
    settings: AlertSettings,
    alerting: Set<String> = []
) -> [AlertCondition] {
    guard settings.isEnabled, let forecast, let latest else { return [] }
    let band = Band(mmolPerL: latest.value, thresholds: thresholds)
    let reading = [formatMmolPerL(latest.value), latest.trend.arrowText].compactMap { $0 }.joined(separator: " ")

    func minutesUntil(_ crossing: Date?, family: String, lead: TimeInterval) -> Int? {
        guard let crossing else { return nil }
        let window = alerting.contains(family) ? lead * 2 : lead
        let remaining = max(0, crossing.timeIntervalSince(now))
        guard remaining <= window else { return nil }
        return max(5, Int((remaining / 300).rounded()) * 5)
    }

    var conditions: [AlertCondition] = []
    if settings.predictsLow, band != .low, band != .urgentLow,
       let minutes = minutesUntil(forecast.lowCrossing, family: ForecastAlertFamily.low, lead: settings.predictedLowLead) {
        conditions.append(AlertCondition(
            family: ForecastAlertFamily.low,
            rank: 0,
            repeatInterval: settings.lowRepeatInterval,
            title: "Heading low: \(reading)",
            repeatTitle: "Still heading low: \(reading)",
            body: "Predicted below \(formatMmolPerL(thresholds.low)) in about \(minutes) min. Check, and consider carbs. Sugarbar is not a medical device.",
            isUrgent: false
        ))
    }
    if settings.predictsHigh, band != .high, band != .urgentHigh,
       let minutes = minutesUntil(forecast.highCrossing, family: ForecastAlertFamily.high, lead: settings.predictedHighLead) {
        conditions.append(AlertCondition(
            family: ForecastAlertFamily.high,
            rank: 0,
            repeatInterval: settings.highRepeatInterval,
            title: "Heading high: \(reading)",
            repeatTitle: "Still heading high: \(reading)",
            body: "Predicted above \(formatMmolPerL(thresholds.high)) in about \(minutes) min. Check. Sugarbar is not a medical device.",
            isUrgent: false
        ))
    }
    return conditions
}

public protocol AlertStateStore: Sendable {
    func load() -> AlertState
    func save(_ state: AlertState)
}

/// Per-app (not App Group) so the Mac and the phone each alert on their own.
public final class UserDefaultsAlertStateStore: AlertStateStore, @unchecked Sendable {
    private static let key = "alerts.state"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> AlertState {
        guard let data = defaults.data(forKey: Self.key) else { return AlertState() }
        return (try? JSONDecoder().decode(AlertState.self, from: data)) ?? AlertState()
    }

    public func save(_ state: AlertState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

public final class InMemoryAlertStateStore: AlertStateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var state = AlertState()

    public init() {}

    public func load() -> AlertState {
        lock.withLock { state }
    }

    public func save(_ state: AlertState) {
        lock.withLock { self.state = state }
    }
}
