import CryptoKit
import Foundation

struct LocalRecord {
    let payload: JSONValue
    let fingerprint: String
    /// When the thing itself happened, for a first sync of data that predates sync.
    let timestamp: Date?
}

func syncFingerprint(_ payload: JSONValue) -> String {
    SHA256.hash(data: Data(payload.canonicalText.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// A remote change ready to apply: nil payload is a deletion.
struct RemoteRecord {
    let id: String
    let payload: JSONValue?
}

/// Reads and writes the records the engine syncs, in the app's own stores.
struct SyncLocalRecords {
    let meals: MealStore
    let history: HistoryStore
    let settings: SettingsStore

    func records(of kind: SyncKind) -> [String: LocalRecord] {
        switch kind {
        case .meal:
            return Dictionary(meals.load().compactMap { meal in record(meal, timestamp: meal.timestamp).map { (meal.id.uuidString, $0) } }) { $1 }
        case .manualDose:
            return Dictionary(history.allDoses().filter(\.isManual).compactMap { dose in record(dose, timestamp: dose.timestamp).map { (dose.id, $0) } }) { $1 }
        default:
            guard let record = settingsRecord(kind, of: settings.load()) else { return [:] }
            return [SyncKind.settingsRecordId: record]
        }
    }

    /// Applies remote records of one kind and returns the local fingerprint of each afterwards (nil when gone).
    /// Records that do not decode are left out of the result, and untouched.
    func apply(_ remote: [RemoteRecord], of kind: SyncKind) -> [String: String?] {
        switch kind {
        case .meal: applyMeals(remote)
        case .manualDose: applyManualDoses(remote)
        default: applySettings(remote, of: kind)
        }
    }

    func defaultFingerprint(of kind: SyncKind) -> String? {
        settingsRecord(kind, of: .default)?.fingerprint
    }

    private func record<T: Encodable>(_ value: T, timestamp: Date?) -> LocalRecord? {
        guard let payload = try? JSONValue(encoding: value) else { return nil }
        return LocalRecord(payload: payload, fingerprint: syncFingerprint(payload), timestamp: timestamp)
    }

    private func settingsRecord(_ kind: SyncKind, of settings: Settings) -> LocalRecord? {
        switch kind {
        case .thresholds: record(settings.thresholds, timestamp: nil)
        case .therapy: record(settings.therapy, timestamp: nil)
        case .dosing: record(settings.dosing, timestamp: nil)
        case .alerts: record(settings.alerts, timestamp: nil)
        case .therapyLearning: record(settings.therapyLearning, timestamp: nil)
        case .meal, .manualDose: nil
        }
    }

    private func applyMeals(_ remote: [RemoteRecord]) -> [String: String?] {
        var byId = Dictionary(meals.load().map { ($0.id, $0) }) { $1 }
        var touched: [UUID: String] = [:]
        for record in remote {
            guard let id = UUID(uuidString: record.id) else { continue }
            if let payload = record.payload {
                guard let meal = try? payload.decode(Meal.self), meal.id == id else { continue }
                byId[id] = meal
            } else {
                byId[id] = nil
            }
            touched[id] = record.id
        }
        guard !touched.isEmpty else { return [:] }
        meals.save(byId.values.sorted { $0.timestamp < $1.timestamp })
        let stored = Dictionary(meals.load().map { ($0.id, $0) }) { $1 }
        return Dictionary(touched.map { id, remoteId in (remoteId, stored[id].flatMap { self.record($0, timestamp: nil)?.fingerprint }) }) { $1 }
    }

    private func applyManualDoses(_ remote: [RemoteRecord]) -> [String: String?] {
        var local = Dictionary(history.allDoses().filter(\.isManual).map { ($0.id, $0) }) { $1 }
        var result: [String: String?] = [:]
        for record in remote {
            if let payload = record.payload {
                guard let dose = try? payload.decode(InsulinDose.self), dose.isManual, dose.id == record.id else { continue }
                if let old = local[record.id] { history.replace(old, with: dose) } else { history.append(doses: [dose]) }
                local[record.id] = dose
                result[record.id] = self.record(dose, timestamp: nil)?.fingerprint
            } else {
                if let old = local[record.id] { history.delete(dose: old) }
                local[record.id] = nil
                result[record.id] = .some(nil)
            }
        }
        return result
    }

    private func applySettings(_ remote: [RemoteRecord], of kind: SyncKind) -> [String: String?] {
        guard let record = remote.last(where: { $0.id == SyncKind.settingsRecordId }), let payload = record.payload else { return [:] }
        var updated = settings.load()
        do {
            switch kind {
            case .thresholds:
                let thresholds = try payload.decode(Thresholds.self)
                guard thresholds.isValid else { return [:] }
                updated.thresholds = thresholds
            case .therapy:
                let therapy = try payload.decode(TherapySettings.self)
                guard therapy.isValid else { return [:] }
                updated.therapy = therapy
            case .dosing: updated.dosing = try payload.decode(DosingSettings.self)
            case .alerts: updated.alerts = try payload.decode(AlertSettings.self)
            case .therapyLearning: updated.therapyLearning = try payload.decode(TherapyLearning.self)
            case .meal, .manualDose: return [:]
            }
        } catch {
            return [:]
        }
        settings.save(updated)
        return [record.id: settingsRecord(kind, of: settings.load())?.fingerprint]
    }
}
