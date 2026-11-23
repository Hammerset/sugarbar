import Foundation

/// One manual Dose as the Sync Server wrote it to Glooko. Glooko's graph gives it back without an id,
/// so it would otherwise count as a second, real Dose.
public struct GlookoEcho: Codable, Hashable, Sendable {
    public let kind: InsulinKind
    public let t: Int
    public let units: Double

    public init(kind: InsulinKind, t: Int, units: Double) {
        self.kind = kind
        self.t = t
        self.units = units
    }

    func matches(_ dose: InsulinDose) -> Bool {
        dose.kind == kind && abs(dose.units - units) < 0.01 && abs(dose.timestamp.timeIntervalSince1970 - Double(t)) <= 60
    }
}

public enum GlookoItemState: String, Codable, Sendable {
    case sent, waiting, failed, removed, deleted, imported
}

/// What the Sync Server reports for one Meal or manual Dose it sends to Glooko.
public struct GlookoItemStatus: Codable, Equatable, Sendable {
    /// Nil for a state this version does not know.
    public var state: GlookoItemState?
    public var message: String?
    public var echoes: [GlookoEcho]?

    public init(state: GlookoItemState?, message: String? = nil, echoes: [GlookoEcho]? = nil) {
        self.state = state
        self.message = message
        self.echoes = echoes
    }

    private enum CodingKeys: String, CodingKey { case state, message, echoes }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = (try? container.decodeIfPresent(GlookoItemState.self, forKey: .state)) ?? nil
        message = try container.decodeIfPresent(String.self, forKey: .message)
        echoes = (try? container.decodeIfPresent([GlookoEcho].self, forKey: .echoes)) ?? nil
    }
}

public struct GlookoBridgeSummary: Codable, Equatable, Sendable {
    public var state: String
    public var message: String?
}

public struct GlookoBridgeSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var timeZone: String?
}

/// The Sync Server's Glooko bridge as this device last heard of it, through ordinary sync records.
public struct GlookoBridgeInfo: Codable, Equatable, Sendable {
    static let settingsKind = "glookoSettings"
    static let statusKind = "glookoStatus"
    static let summaryKind = "glookoBridge"
    static let kinds: Set<String> = [settingsKind, statusKind, summaryKind]

    public var settings: GlookoBridgeSettings?
    var settingsUpdatedAt: SyncStamp?
    public var summary: GlookoBridgeSummary?
    public var items: [String: GlookoItemStatus] = [:]

    public init() {}

    public var isSending: Bool { settings?.enabled == true }

    public func status(of meal: Meal) -> GlookoItemStatus? { items["meal/\(meal.id.uuidString)"] }
    public func status(of dose: InsulinDose) -> GlookoItemStatus? { items["manualDose/\(dose.id)"] }

    var echoes: Set<GlookoEcho> { Set(items.values.flatMap { $0.echoes ?? [] }) }

    /// "Connected to Glooko", or what stops the server from sending.
    public var summaryLine: String? {
        guard isSending else { return nil }
        guard let summary else { return "Waiting for the server…" }
        if summary.state == "ok" { return "Connected to Glooko" }
        return summary.message ?? "Not sending (\(summary.state))"
    }

    public var hasProblem: Bool { isSending && summary.map { $0.state != "ok" && $0.state != "off" } == true }
}

public struct GlookoItemLabel: Equatable, Sendable {
    public let text: String
    public let detail: String?
    public let isProblem: Bool
}

/// A few words for a recent Meal or manual Dose; nil when there is nothing to say.
public func glookoItemLabel(_ status: GlookoItemStatus?, isSending: Bool) -> GlookoItemLabel? {
    switch status?.state {
    case .sent: GlookoItemLabel(text: "In Glooko", detail: nil, isProblem: false)
    case .imported: GlookoItemLabel(text: "From Glooko", detail: nil, isProblem: false)
    case .failed: GlookoItemLabel(text: "Not in Glooko", detail: status?.message, isProblem: true)
    case .removed: GlookoItemLabel(text: "Removed from Glooko", detail: status?.message, isProblem: false)
    case .deleted: nil
    case .waiting: GlookoItemLabel(text: "Waiting for Glooko", detail: status?.message, isProblem: false)
    case nil: isSending ? GlookoItemLabel(text: "Waiting for Glooko", detail: nil, isProblem: false) : nil
    }
}
