import Foundation

public struct Settings: Equatable, Sendable {
    public var thresholds: Thresholds
    public var pollCadence: TimeInterval
    public var selectedPatientId: String?
    public var disclaimerAcknowledged: Bool

    public init(
        thresholds: Thresholds,
        pollCadence: TimeInterval,
        selectedPatientId: String?,
        disclaimerAcknowledged: Bool
    ) {
        self.thresholds = thresholds
        self.pollCadence = pollCadence
        self.selectedPatientId = selectedPatientId
        self.disclaimerAcknowledged = disclaimerAcknowledged
    }

    public static let cadenceRange: ClosedRange<TimeInterval> = 30...300

    public static let `default` = Settings(
        thresholds: .standard,
        pollCadence: 60,
        selectedPatientId: nil,
        disclaimerAcknowledged: false
    )
}

public protocol SettingsStore: Sendable {
    func load() -> Settings
    func save(_ settings: Settings)
}

/// UserDefaults-backed store. Reads are defensive: a missing key falls back to the
/// default, out-of-order custom thresholds collapse to `.standard`, and an out-of-range
/// cadence is clamped — so a tampered or partially-written domain can never poison the app.
public final class UserDefaultsSettingsStore: SettingsStore, @unchecked Sendable {
    private enum Key {
        static let urgentLow = "thresholds.urgentLow"
        static let low = "thresholds.low"
        static let high = "thresholds.high"
        static let urgentHigh = "thresholds.urgentHigh"
        static let pollCadence = "poll.cadence"
        static let selectedPatientId = "connection.patientId"
        static let disclaimerAcknowledged = "disclaimer.acknowledged"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> Settings {
        Settings(
            thresholds: loadThresholds(),
            pollCadence: loadCadence(),
            selectedPatientId: defaults.string(forKey: Key.selectedPatientId),
            disclaimerAcknowledged: defaults.bool(forKey: Key.disclaimerAcknowledged)
        )
    }

    public func save(_ settings: Settings) {
        defaults.set(settings.thresholds.urgentLow, forKey: Key.urgentLow)
        defaults.set(settings.thresholds.low, forKey: Key.low)
        defaults.set(settings.thresholds.high, forKey: Key.high)
        defaults.set(settings.thresholds.urgentHigh, forKey: Key.urgentHigh)
        defaults.set(settings.pollCadence, forKey: Key.pollCadence)
        defaults.set(settings.disclaimerAcknowledged, forKey: Key.disclaimerAcknowledged)
        if let patientId = settings.selectedPatientId {
            defaults.set(patientId, forKey: Key.selectedPatientId)
        } else {
            defaults.removeObject(forKey: Key.selectedPatientId)
        }
    }

    private func loadThresholds() -> Thresholds {
        guard defaults.object(forKey: Key.urgentLow) != nil else { return .standard }
        return Thresholds.validated(
            urgentLow: defaults.double(forKey: Key.urgentLow),
            low: defaults.double(forKey: Key.low),
            high: defaults.double(forKey: Key.high),
            urgentHigh: defaults.double(forKey: Key.urgentHigh)
        ) ?? .standard
    }

    private func loadCadence() -> TimeInterval {
        guard defaults.object(forKey: Key.pollCadence) != nil else { return Settings.default.pollCadence }
        let stored = defaults.double(forKey: Key.pollCadence)
        return min(max(stored, Settings.cadenceRange.lowerBound), Settings.cadenceRange.upperBound)
    }
}

public final class InMemorySettingsStore: SettingsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var settings: Settings

    public init(_ settings: Settings = .default) {
        self.settings = settings
    }

    public func load() -> Settings {
        lock.withLock { settings }
    }

    public func save(_ settings: Settings) {
        lock.withLock { self.settings = settings }
    }
}
