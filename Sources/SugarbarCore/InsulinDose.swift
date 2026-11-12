import Foundation

public enum InsulinKind: String, Codable, Sendable {
    case bolus
    case basal
}

public enum DoseOrigin: String, Codable, Sendable {
    case glooko
    case manual
}

/// One injection: from Glooko (a pen dose synced over NFC, or one typed into the Glooko app),
/// or entered in sugarbar before the pen is synced. Timing is when the pen fired, not when it synced.
public struct InsulinDose: Equatable, Sendable, Codable, Identifiable {
    public let kind: InsulinKind
    public let units: Double
    public let timestamp: Date
    public let insulinName: String?
    public let deviceName: String?
    public let origin: DoseOrigin
    public let entryId: UUID?

    public init(kind: InsulinKind, units: Double, timestamp: Date, insulinName: String?, deviceName: String?) {
        self.kind = kind
        self.units = units
        self.timestamp = timestamp
        self.insulinName = insulinName
        self.deviceName = deviceName
        self.origin = .glooko
        self.entryId = nil
    }

    public static func manual(
        kind: InsulinKind,
        units: Double,
        timestamp: Date,
        insulinName: String?,
        entryId: UUID = UUID()
    ) -> InsulinDose {
        InsulinDose(kind: kind, units: units, timestamp: timestamp, insulinName: insulinName, entryId: entryId)
    }

    private init(kind: InsulinKind, units: Double, timestamp: Date, insulinName: String?, entryId: UUID) {
        self.kind = kind
        self.units = units
        self.timestamp = timestamp
        self.insulinName = insulinName
        self.deviceName = nil
        self.origin = .manual
        self.entryId = entryId
    }

    /// Lines written before manual entry existed carry no origin and are Glooko Doses.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(InsulinKind.self, forKey: .kind)
        units = try container.decode(Double.self, forKey: .units)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        insulinName = try container.decodeIfPresent(String.self, forKey: .insulinName)
        deviceName = try container.decodeIfPresent(String.self, forKey: .deviceName)
        origin = try container.decodeIfPresent(DoseOrigin.self, forKey: .origin) ?? .glooko
        entryId = try container.decodeIfPresent(UUID.self, forKey: .entryId)
    }

    /// A Glooko Dose is keyed by kind and time so a re-sync replaces it; a manual one keeps its
    /// identity across edits, and two entered in the same minute stay apart.
    public var id: String {
        if origin == .manual, let entryId { return "manual-\(entryId.uuidString)" }
        return "\(kind.rawValue)-\(timestamp.timeIntervalSince1970)"
    }

    public var isManual: Bool { origin == .manual }

    public var isFromPen: Bool { deviceName != nil }
}

/// A manual Dose stands in for its Pen Dose until Glooko has it: a Glooko Dose of the same kind and
/// units within this window supersedes it. Pen clocks drift and people log a little late.
public let manualDoseMatchTolerance: TimeInterval = 20 * 60

/// Drops each manual Dose that a Glooko Dose supersedes, pairing each with at most one partner,
/// closest in time first. Doses whose units differ are both kept.
public func reconcileDoses(_ doses: [InsulinDose], tolerance: TimeInterval = manualDoseMatchTolerance) -> [InsulinDose] {
    let manual = doses.filter(\.isManual)
    let glooko = doses.filter { !$0.isManual }
    let candidates = manual.flatMap { entry in
        glooko.compactMap { synced -> (manual: String, glooko: String, gap: TimeInterval)? in
            let gap = abs(synced.timestamp.timeIntervalSince(entry.timestamp))
            guard synced.kind == entry.kind, abs(synced.units - entry.units) < 0.01, gap <= tolerance else { return nil }
            return (entry.id, synced.id, gap)
        }
    }
    var supersededManual: Set<String> = []
    var usedGlooko: Set<String> = []
    for pair in candidates.sorted(by: { $0.gap < $1.gap })
    where !supersededManual.contains(pair.manual) && !usedGlooko.contains(pair.glooko) {
        supersededManual.insert(pair.manual)
        usedGlooko.insert(pair.glooko)
    }
    return doses
        .filter { !supersededManual.contains($0.id) }
        .sorted { $0.timestamp < $1.timestamp }
}

/// Every dose within `tolerance` of a hovered date, oldest first.
public func insulinDoses(near date: Date, in doses: [InsulinDose], tolerance: TimeInterval) -> [InsulinDose] {
    doses
        .filter { abs($0.timestamp.timeIntervalSince(date)) <= tolerance }
        .sorted { $0.timestamp < $1.timestamp }
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
