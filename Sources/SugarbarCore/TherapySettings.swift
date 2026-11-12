import Foundation

/// The personal factors the Forecast needs. Sensitivity and carb ratio have no defaults:
/// until the user enters both, there is no Forecast.
public struct TherapySettings: Equatable, Sendable {
    /// mmol/L that one unit of Bolus insulin lowers glucose by.
    public var insulinSensitivity: Double?
    /// Grams of carbohydrate covered by one unit of Bolus insulin.
    public var carbRatio: Double?
    public var insulinDuration: TimeInterval
    public var insulinPeak: TimeInterval
    public var carbAbsorptionTime: TimeInterval

    public init(
        insulinSensitivity: Double? = nil,
        carbRatio: Double? = nil,
        insulinDuration: TimeInterval = 6 * 3600,
        insulinPeak: TimeInterval = 75 * 60,
        carbAbsorptionTime: TimeInterval = 3 * 3600
    ) {
        self.insulinSensitivity = insulinSensitivity
        self.carbRatio = carbRatio
        self.insulinDuration = insulinDuration
        self.insulinPeak = insulinPeak
        self.carbAbsorptionTime = carbAbsorptionTime
    }

    public static let `default` = TherapySettings()

    public static let sensitivityRange: ClosedRange<Double> = 0.2...10
    public static let carbRatioRange: ClosedRange<Double> = 1...100
    public static let insulinDurationRange: ClosedRange<TimeInterval> = (4 * 3600)...(8 * 3600)
    public static let insulinPeakRange: ClosedRange<TimeInterval> = (30 * 60)...(120 * 60)
    public static let carbAbsorptionRange: ClosedRange<TimeInterval> = (30 * 60)...(6 * 3600)

    public var isComplete: Bool { insulinSensitivity != nil && carbRatio != nil }

    /// Nil when every entered value is sane, otherwise a message naming the first problem.
    public var validationError: String? {
        if let insulinSensitivity, !Self.sensitivityRange.contains(insulinSensitivity) {
            return "Insulin sensitivity must be between \(format(Self.sensitivityRange)) mmol/L per unit."
        }
        if let carbRatio, !Self.carbRatioRange.contains(carbRatio) {
            return "Carb ratio must be between \(format(Self.carbRatioRange)) g per unit."
        }
        if !Self.insulinDurationRange.contains(insulinDuration) {
            return "Insulin duration must be between 4 and 8 hours."
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
        return nil
    }

    public var isValid: Bool { validationError == nil }

    private func format(_ range: ClosedRange<Double>) -> String {
        "\(formatNumber(range.lowerBound))–\(formatNumber(range.upperBound))"
    }

    private func formatNumber(_ value: Double) -> String {
        value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }
}

extension TherapySettings {
    private enum Key {
        static let insulinSensitivity = "therapy.insulinSensitivity"
        static let carbRatio = "therapy.carbRatio"
        static let insulinDuration = "therapy.insulinDuration"
        static let insulinPeak = "therapy.insulinPeak"
        static let carbAbsorptionTime = "therapy.carbAbsorptionTime"
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
            carbAbsorptionTime: within(stored(Key.carbAbsorptionTime), carbAbsorptionRange) ?? fallback.carbAbsorptionTime
        )
        if !therapy.isValid {
            therapy.insulinDuration = fallback.insulinDuration
            therapy.insulinPeak = fallback.insulinPeak
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
    }
}
