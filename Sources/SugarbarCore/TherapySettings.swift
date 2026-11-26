import Foundation

/// The personal factors the Forecast needs. Sensitivity and carb ratio have no defaults:
/// until the user enters both, there is no Forecast.
public struct TherapySettings: Hashable, Sendable, Codable {
    /// mmol/L that one unit of Bolus insulin lowers glucose by.
    public var insulinSensitivity: Double?
    /// Grams of carbohydrate covered by one unit of Bolus insulin.
    public var carbRatio: Double?
    public var insulinDuration: TimeInterval
    public var insulinPeak: TimeInterval
    /// How long a normal Meal's carbs take to absorb.
    public var carbAbsorptionTime: TimeInterval
    public var fastCarbAbsorptionTime: TimeInterval
    public var slowCarbAbsorptionTime: TimeInterval
    /// How long the part of the CGM trend that insulin and carbs do not explain keeps acting.
    public var trendBlendDuration: TimeInterval
    /// The slowest and fastest the Forecast may run the remaining carbs when recent glucose disagrees.
    public var slowestCarbFactor: Double
    public var fastestCarbFactor: Double

    /// Fast and slow absorption default to half and one and a half times the normal time.
    public init(
        insulinSensitivity: Double? = nil,
        carbRatio: Double? = nil,
        insulinDuration: TimeInterval = 6 * 3600,
        insulinPeak: TimeInterval = 75 * 60,
        carbAbsorptionTime: TimeInterval = 3 * 3600,
        fastCarbAbsorptionTime: TimeInterval? = nil,
        slowCarbAbsorptionTime: TimeInterval? = nil,
        trendBlendDuration: TimeInterval = 30 * 60,
        slowestCarbFactor: Double = 0.25,
        fastestCarbFactor: Double = 2.0
    ) {
        self.insulinSensitivity = insulinSensitivity
        self.carbRatio = carbRatio
        self.insulinDuration = insulinDuration
        self.insulinPeak = insulinPeak
        self.carbAbsorptionTime = carbAbsorptionTime
        self.fastCarbAbsorptionTime = fastCarbAbsorptionTime ?? carbAbsorptionTime * 0.5
        self.slowCarbAbsorptionTime = slowCarbAbsorptionTime ?? carbAbsorptionTime * 1.5
        self.trendBlendDuration = trendBlendDuration
        self.slowestCarbFactor = slowestCarbFactor
        self.fastestCarbFactor = fastestCarbFactor
    }

    public static let `default` = TherapySettings()

    public static let sensitivityRange: ClosedRange<Double> = 0.2...10
    public static let carbRatioRange: ClosedRange<Double> = 1...100
    public static let insulinDurationRange: ClosedRange<TimeInterval> = (3 * 3600)...(8 * 3600)
    public static let insulinPeakRange: ClosedRange<TimeInterval> = (30 * 60)...(120 * 60)
    public static let carbAbsorptionRange: ClosedRange<TimeInterval> = (30 * 60)...(6 * 3600)
    public static let fastCarbAbsorptionRange: ClosedRange<TimeInterval> = (15 * 60)...(6 * 3600)
    public static let slowCarbAbsorptionRange: ClosedRange<TimeInterval> = (30 * 60)...(9 * 3600)
    public static let trendBlendRange: ClosedRange<TimeInterval> = (10 * 60)...(60 * 60)
    public static let slowestCarbFactorRange: ClosedRange<Double> = 0.1...0.8
    public static let fastestCarbFactorRange: ClosedRange<Double> = 1.2...3.0

    public var isComplete: Bool { insulinSensitivity != nil && carbRatio != nil }

    public func absorptionTime(_ speed: CarbAbsorption) -> TimeInterval {
        switch speed {
        case .fast: fastCarbAbsorptionTime
        case .normal: carbAbsorptionTime
        case .slow: slowCarbAbsorptionTime
        }
    }

    public var carbFactorRange: ClosedRange<Double> { slowestCarbFactor...fastestCarbFactor }

    /// Nil when every entered value is sane, otherwise a message naming the first problem.
    public var validationError: String? {
        if let insulinSensitivity, !Self.sensitivityRange.contains(insulinSensitivity) {
            return "Insulin sensitivity must be between \(format(Self.sensitivityRange)) mmol/L per unit."
        }
        if let carbRatio, !Self.carbRatioRange.contains(carbRatio) {
            return "Carb ratio must be between \(format(Self.carbRatioRange)) g per unit."
        }
        if !Self.insulinDurationRange.contains(insulinDuration) {
            return "Insulin duration must be between 3 and 8 hours."
        }
        if !Self.insulinPeakRange.contains(insulinPeak) {
            return "Insulin peak must be between 30 and 120 minutes."
        }
        // The exponential model needs the peak in the first half of the duration.
        if insulinPeak * 2 >= insulinDuration {
            return "Insulin peak must be less than half the insulin duration."
        }
        if !Self.carbAbsorptionRange.contains(carbAbsorptionTime) {
            return "Carb absorption time must be between 30 minutes and 6 hours."
        }
        if !Self.fastCarbAbsorptionRange.contains(fastCarbAbsorptionTime) || fastCarbAbsorptionTime > carbAbsorptionTime {
            return "Fast carb absorption must be at least 15 minutes and no longer than normal."
        }
        if !Self.slowCarbAbsorptionRange.contains(slowCarbAbsorptionTime) || slowCarbAbsorptionTime < carbAbsorptionTime {
            return "Slow carb absorption must be at most 9 hours and no shorter than normal."
        }
        if !Self.trendBlendRange.contains(trendBlendDuration) {
            return "Trend blend must be between 10 and 60 minutes."
        }
        if !Self.slowestCarbFactorRange.contains(slowestCarbFactor) || !Self.fastestCarbFactorRange.contains(fastestCarbFactor) {
            return "Carb correction limits must be 0.1–0.8× and 1.2–3×."
        }
        return nil
    }

    public var isValid: Bool { validationError == nil }

    private func format(_ range: ClosedRange<Double>) -> String {
        "\(formatNumber(range.lowerBound))–\(formatNumber(range.upperBound))"
    }

    private func formatNumber(_ value: Double) -> String {
        value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    private enum CodingKeys: String, CodingKey {
        case insulinSensitivity, carbRatio, insulinDuration, insulinPeak, carbAbsorptionTime
        case fastCarbAbsorptionTime, slowCarbAbsorptionTime, trendBlendDuration, slowestCarbFactor, fastestCarbFactor
    }

    /// Settings synced before per-class absorption and forecast tuning existed decode to the old behaviour.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = TherapySettings.default
        self.init(
            insulinSensitivity: try container.decodeIfPresent(Double.self, forKey: .insulinSensitivity),
            carbRatio: try container.decodeIfPresent(Double.self, forKey: .carbRatio),
            insulinDuration: try container.decode(TimeInterval.self, forKey: .insulinDuration),
            insulinPeak: try container.decode(TimeInterval.self, forKey: .insulinPeak),
            carbAbsorptionTime: try container.decode(TimeInterval.self, forKey: .carbAbsorptionTime),
            fastCarbAbsorptionTime: try container.decodeIfPresent(TimeInterval.self, forKey: .fastCarbAbsorptionTime),
            slowCarbAbsorptionTime: try container.decodeIfPresent(TimeInterval.self, forKey: .slowCarbAbsorptionTime),
            trendBlendDuration: try container.decodeIfPresent(TimeInterval.self, forKey: .trendBlendDuration) ?? fallback.trendBlendDuration,
            slowestCarbFactor: try container.decodeIfPresent(Double.self, forKey: .slowestCarbFactor) ?? fallback.slowestCarbFactor,
            fastestCarbFactor: try container.decodeIfPresent(Double.self, forKey: .fastestCarbFactor) ?? fallback.fastestCarbFactor
        )
    }
}

extension TherapySettings {
    private enum Key {
        static let insulinSensitivity = "therapy.insulinSensitivity"
        static let carbRatio = "therapy.carbRatio"
        static let insulinDuration = "therapy.insulinDuration"
        static let insulinPeak = "therapy.insulinPeak"
        static let carbAbsorptionTime = "therapy.carbAbsorptionTime"
        static let fastCarbAbsorptionTime = "therapy.fastCarbAbsorptionTime"
        static let slowCarbAbsorptionTime = "therapy.slowCarbAbsorptionTime"
        static let trendBlendDuration = "therapy.trendBlendDuration"
        static let slowestCarbFactor = "therapy.slowestCarbFactor"
        static let fastestCarbFactor = "therapy.fastestCarbFactor"
    }

    /// Missing keys fall back to defaults; an out-of-range stored value is dropped
    /// (sensitivity/ratio to unset, timings to their defaults) rather than trusted.
    static func load(from defaults: UserDefaults) -> TherapySettings {
        func stored(_ key: String) -> Double? {
            defaults.object(forKey: key) == nil ? nil : defaults.double(forKey: key)
        }
        func within(_ value: Double?, _ range: ClosedRange<Double>) -> Double? {
            value.flatMap { range.contains($0) ? $0 : nil }
        }
        let fallback = TherapySettings.default
        var therapy = TherapySettings(
            insulinSensitivity: within(stored(Key.insulinSensitivity), sensitivityRange),
            carbRatio: within(stored(Key.carbRatio), carbRatioRange),
            insulinDuration: within(stored(Key.insulinDuration), insulinDurationRange) ?? fallback.insulinDuration,
            insulinPeak: within(stored(Key.insulinPeak), insulinPeakRange) ?? fallback.insulinPeak,
            carbAbsorptionTime: within(stored(Key.carbAbsorptionTime), carbAbsorptionRange) ?? fallback.carbAbsorptionTime,
            fastCarbAbsorptionTime: within(stored(Key.fastCarbAbsorptionTime), fastCarbAbsorptionRange),
            slowCarbAbsorptionTime: within(stored(Key.slowCarbAbsorptionTime), slowCarbAbsorptionRange),
            trendBlendDuration: within(stored(Key.trendBlendDuration), trendBlendRange) ?? fallback.trendBlendDuration,
            slowestCarbFactor: within(stored(Key.slowestCarbFactor), slowestCarbFactorRange) ?? fallback.slowestCarbFactor,
            fastestCarbFactor: within(stored(Key.fastestCarbFactor), fastestCarbFactorRange) ?? fallback.fastestCarbFactor
        )
        if !therapy.isValid {
            therapy.insulinDuration = fallback.insulinDuration
            therapy.insulinPeak = fallback.insulinPeak
            therapy.fastCarbAbsorptionTime = therapy.carbAbsorptionTime * 0.5
            therapy.slowCarbAbsorptionTime = therapy.carbAbsorptionTime * 1.5
        }
        return therapy
    }

    func save(to defaults: UserDefaults) {
        func set(_ value: Double?, _ key: String) {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        set(insulinSensitivity, Key.insulinSensitivity)
        set(carbRatio, Key.carbRatio)
        set(insulinDuration, Key.insulinDuration)
        set(insulinPeak, Key.insulinPeak)
        set(carbAbsorptionTime, Key.carbAbsorptionTime)
        set(fastCarbAbsorptionTime, Key.fastCarbAbsorptionTime)
        set(slowCarbAbsorptionTime, Key.slowCarbAbsorptionTime)
        set(trendBlendDuration, Key.trendBlendDuration)
        set(slowestCarbFactor, Key.slowestCarbFactor)
        set(fastestCarbFactor, Key.fastestCarbFactor)
    }
}
