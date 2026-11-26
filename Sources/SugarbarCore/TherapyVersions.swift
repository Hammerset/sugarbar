import Foundation

/// The whole set of Therapy Settings from one change on, so any of them can be restored.
public struct TherapyVersion: Equatable, Sendable, Codable, Identifiable {
    public let id: UUID
    /// `distantPast` for the settings in place before versions were kept.
    public let date: Date
    public let therapy: TherapySettings
    public let evidence: String

    public init(id: UUID = UUID(), date: Date, therapy: TherapySettings, evidence: String) {
        self.id = id
        self.date = date
        self.therapy = therapy
        self.evidence = evidence
    }

    public var isBaseline: Bool { date == .distantPast }
}

extension TherapyLearning {
    static let maximumVersions = 30

    /// Appends `therapy` as a new version, starting from a baseline of `previous` when none was kept yet.
    mutating func recordVersion(_ therapy: TherapySettings, previous: TherapySettings, at date: Date, evidence: String) {
        guard therapy != previous || versions.isEmpty else { return }
        if versions.isEmpty {
            versions.append(TherapyVersion(date: .distantPast, therapy: previous, evidence: "Before versions were kept"))
        }
        versions.append(TherapyVersion(date: date, therapy: therapy, evidence: evidence))
        if versions.count > Self.maximumVersions { versions.removeFirst(versions.count - Self.maximumVersions) }
    }
}

public extension Settings {
    /// The Calibration proposal to show: made against the settings in place now and not rejected.
    func visibleProposal(_ report: CalibrationReport?) -> CalibrationProposal? {
        guard let proposal = report?.proposal,
              proposal.changes.allSatisfy({ therapy[$0.quantity] == $0.current }),
              therapyLearning.rejectedProposal != proposal.proposedValues
        else { return nil }
        return proposal
    }

    /// Applies every change in `proposal` and keeps a version of the result.
    func approving(_ proposal: CalibrationProposal, at date: Date) -> Settings {
        var proposed = therapy
        for change in proposal.changes { proposed[change.quantity] = change.proposed }
        guard proposed.isValid else { return self }
        return replacingTherapy(with: proposed, at: date, evidence: proposal.evidence)
    }

    func rejecting(_ proposal: CalibrationProposal) -> Settings {
        var updated = self
        updated.therapyLearning.rejectedProposal = proposal.proposedValues
        return updated
    }

    /// Restores a version's settings, as a new version of its own.
    func rollingBack(to version: TherapyVersion, at date: Date) -> Settings {
        let when = version.isBaseline ? "the settings before versions were kept" : "the version of \(version.date.formatted(date: .abbreviated, time: .shortened))"
        return replacingTherapy(with: version.therapy, at: date, evidence: "Rolled back to \(when)")
    }

    func replacingTherapy(with edited: TherapySettings, at date: Date, evidence: String) -> Settings {
        var updated = self
        updated.therapy = edited
        for quantity in TherapyQuantity.allCases where therapy[quantity] != edited[quantity] {
            updated.therapyLearning.record(TherapyChange(date: date, quantity: quantity, old: therapy[quantity], new: edited[quantity], evidence: evidence))
        }
        updated.therapyLearning.recordVersion(edited, previous: therapy, at: date, evidence: evidence)
        return updated
    }
}

public extension CalibrationProposal {
    var proposedValues: [TherapyQuantity: Double] {
        Dictionary(uniqueKeysWithValues: changes.map { ($0.quantity, $0.proposed) })
    }

    var evidence: String {
        var sources: [String] = []
        if corrections > 0 { sources.append("\(corrections) \(corrections == 1 ? "correction" : "corrections")") }
        if meals > 0 { sources.append("\(meals) \(meals == 1 ? "meal" : "meals")") }
        return "Calibrated from \(sources.joined(separator: " and ")): held-out error ±\(String(format: "%.2f", heldOutError)) → ±\(String(format: "%.2f", proposedHeldOutError)) mmol/L"
    }
}

/// How the Forecast logged on this device did while each version was in place.
public func versionAccuracy(
    _ versions: [TherapyVersion],
    log: [ForecastLogEntry],
    readings: [Reading],
    alerts: AlertSettings,
    now: Date
) -> [UUID: ForecastScorecard] {
    let sorted = versions.sorted { $0.date < $1.date }
    var scores: [UUID: ForecastScorecard] = [:]
    for (index, version) in sorted.enumerated() {
        let end = index + 1 < sorted.count ? sorted[index + 1].date : now
        let entries = log.filter { $0.date >= version.date && $0.date < end }
        guard !entries.isEmpty else { continue }
        scores[version.id] = scoreForecasts(entries, readings: readings, rules: AlertScoringRules(alerts: alerts), now: now)
    }
    return scores
}

public func versionAccuracy(settings: Settings, history: HistoryStore, log: ForecastLogStore, now: Date = Date()) -> [UUID: ForecastScorecard] {
    let span = now.addingTimeInterval(-forecastLogRetention)...now
    return versionAccuracy(
        settings.therapyLearning.versions, log: log.entries(in: span), readings: history.readings(in: span),
        alerts: settings.alerts, now: now
    )
}
