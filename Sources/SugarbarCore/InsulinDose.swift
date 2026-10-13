import Foundation

public enum InsulinKind: String, Codable, Sendable {
    case bolus
    case basal
}

/// One injection as Glooko records it: a pen dose synced over NFC or a dose the
/// user typed into the Glooko app. Timing is when the pen fired, not when it synced.
public struct InsulinDose: Equatable, Sendable, Codable, Identifiable {
    public let kind: InsulinKind
    public let units: Double
    public let timestamp: Date
    public let insulinName: String?
    public let deviceName: String?

    public init(kind: InsulinKind, units: Double, timestamp: Date, insulinName: String?, deviceName: String?) {
        self.kind = kind
        self.units = units
        self.timestamp = timestamp
        self.insulinName = insulinName
        self.deviceName = deviceName
    }

    public var id: String { "\(kind.rawValue)-\(timestamp.timeIntervalSince1970)" }

    public var isManualEntry: Bool { deviceName == nil }
}

public func insulinDoses(_ doses: [InsulinDose], within window: HistoryWindow, of now: Date) -> [InsulinDose] {
    let cutoff = now.addingTimeInterval(-Double(window.hours) * 3600)
    return doses.filter { $0.timestamp >= cutoff && $0.timestamp <= now }
}

/// The dose closest to a hovered date, if any lies within `tolerance` of it.
public func nearestInsulinDose(to date: Date, in doses: [InsulinDose], tolerance: TimeInterval) -> InsulinDose? {
    doses
        .min { abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date)) }
        .flatMap { abs($0.timestamp.timeIntervalSince(date)) <= tolerance ? $0 : nil }
}

public struct InsulinTotals: Equatable, Sendable {
    public let bolus: Double
    public let basal: Double
}

public func insulinTotals(_ doses: [InsulinDose]) -> InsulinTotals {
    InsulinTotals(
        bolus: doses.filter { $0.kind == .bolus }.reduce(0) { $0 + $1.units },
        basal: doses.filter { $0.kind == .basal }.reduce(0) { $0 + $1.units }
    )
}

public func formatUnits(_ units: Double) -> String {
    units == units.rounded() ? String(format: "%.0f", units) : String(format: "%.1f", units)
}

public let glookoKeychainServicePrefix = "no.ignite.sugarbar.glooko"
public let doseRefreshInterval: TimeInterval = 5 * 60
public let doseLookback: TimeInterval = 24 * 3600
