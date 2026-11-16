import Foundation

public struct SyncStatus: Equatable, Sendable {
    public var lastSync: Date?
    public var pendingCount: Int
    public var lastError: String?

    public init(lastSync: Date? = nil, pendingCount: Int = 0, lastError: String? = nil) {
        self.lastSync = lastSync
        self.pendingCount = pendingCount
        self.lastError = lastError
    }
}

/// What a sync changed on this device, so the app can refresh what depends on it.
public struct SyncAppliedChanges: Equatable, Sendable {
    public var meals: Set<UUID> = []
    public var history = false
    public var settings = false

    public init(meals: Set<UUID> = [], history: Bool = false, settings: Bool = false) {
        self.meals = meals
        self.history = history
        self.settings = settings
    }

    public var isEmpty: Bool { meals.isEmpty && !history && !settings }
}

/// Local-first sync with a Sync Server. Local edits are found by comparing each record with what this
/// device last synced (so every write path is covered), queued in a durable outbox, and pushed with
/// `POST /v1/sync`, which also pulls everything after the cursor. Latest `updatedAt` wins per record.
/// With no configuration it does nothing at all.
@MainActor
public final class SyncEngine {
    public var mealsWillChange: ([UUID]) -> Void = { _ in }
    public var onRemoteChanges: (SyncAppliedChanges) -> Void = { _ in }

    private let configuration: () -> SyncConfiguration?
    private let stateStore: SyncStateStore
    private let local: SyncLocalRecords
    private let history: HistoryStore
    private let transport: HTTPTransport
    private let now: () -> Date
    private let recordBatchSize: Int
    private let readingBatchSize: Int
    private var state: SyncState?

    static let historyDays: TimeInterval = 90 * 86400
    static let downloadOverlap: TimeInterval = 3 * 3600
    static let deepDownloadOverlap: TimeInterval = 3 * 86400
    static let doseDownloadOverlap: TimeInterval = 3 * 86400
    static let deepDownloadInterval: TimeInterval = 86400

    public init(
        configuration: @escaping () -> SyncConfiguration?,
        stateStore: SyncStateStore,
        meals: MealStore,
        history: HistoryStore,
        settings: SettingsStore,
        transport: HTTPTransport,
        now: @escaping () -> Date = Date.init,
        recordBatchSize: Int = 200,
        readingBatchSize: Int = SyncClient.pageLimit
    ) {
        self.configuration = configuration
        self.stateStore = stateStore
        self.local = SyncLocalRecords(meals: meals, history: history, settings: settings)
        self.history = history
        self.transport = transport
        self.now = now
        self.recordBatchSize = recordBatchSize
        self.readingBatchSize = readingBatchSize
    }

    public var status: SyncStatus {
        let state = state ?? stateStore.load()
        return SyncStatus(lastSync: state?.lastSync, pendingCount: state?.pendingCount ?? 0, lastError: state?.lastError)
    }

    /// Queues local edits without touching the network, so each one is stamped close to when it happened.
    public func recordLocalChanges() {
        guard let configuration = configuration() else { return }
        prepareState(for: configuration)
        scan()
        save()
    }

    public func sync() async throws {
        guard let configuration = configuration() else { return }
        prepareState(for: configuration)
        let client = SyncClient(configuration: configuration, transport: transport)
        do {
            scan()
            save()
            try await exchangeRecords(client)
            if state?.hasPulledEverything == false {
                claimUnsyncedSettings()
                state?.hasPulledEverything = true
                save()
                try await exchangeRecords(client)
            }
            try await uploadReadings(client)
            try await uploadGlookoDoses(client)
            try await downloadHistory(client)
            state?.lastSync = now()
            state?.lastError = nil
            save()
        } catch {
            state?.lastError = error.sugarbarMessage
            save()
            throw error
        }
    }

    private func prepareState(for configuration: SyncConfiguration) {
        let url = configuration.serverURL.absoluteString
        if state == nil { state = stateStore.load() }
        if state?.serverURL != url {
            state = SyncState(serverURL: url)
            save()
        }
    }

    private func save() {
        if let state { stateStore.save(state) }
    }

    // MARK: Records

    private func scan() {
        guard var state else { return }
        let stamp = SyncStamp(date: now())
        var stale: [SyncKind: [RemoteRecord]] = [:]
        for kind in SyncKind.allCases {
            let records = local.records(of: kind)
            var entries = state.index[kind] ?? [:]
            let isFirstScan = !state.scannedKinds.contains(kind)
            for (id, record) in records {
                if let entry = entries[id] {
                    if entry.deleted, !kind.isSettings {
                        stale[kind, default: []].append(RemoteRecord(id: id, payload: nil))
                        continue
                    }
                    guard entry.fingerprint != record.fingerprint else { continue }
                    let updatedAt = max(stamp, (entry.updatedAt ?? 0) + 1)
                    entries[id] = SyncIndexEntry(updatedAt: updatedAt, deleted: false, fingerprint: record.fingerprint)
                    state.enqueue(SyncChange(kind: kind.rawValue, id: id, updatedAt: updatedAt, deleted: false, payload: record.payload))
                } else if kind.isSettings {
                    entries[id] = SyncIndexEntry(updatedAt: nil, deleted: false, fingerprint: record.fingerprint)
                } else {
                    // Data from before sync keeps its own time, so a deletion made elsewhere since still wins.
                    let own = record.timestamp.map { SyncStamp(date: $0) } ?? stamp
                    let updatedAt = isFirstScan ? min(stamp, own) : stamp
                    entries[id] = SyncIndexEntry(updatedAt: updatedAt, deleted: false, fingerprint: record.fingerprint)
                    state.enqueue(SyncChange(kind: kind.rawValue, id: id, updatedAt: updatedAt, deleted: false, payload: record.payload))
                }
            }
            if !kind.isSettings {
                for (id, entry) in entries where !entry.deleted && records[id] == nil {
                    let updatedAt = max(stamp, (entry.updatedAt ?? 0) + 1)
                    entries[id] = SyncIndexEntry(updatedAt: updatedAt, deleted: true, fingerprint: nil)
                    state.enqueue(SyncChange(kind: kind.rawValue, id: id, updatedAt: updatedAt, deleted: true, payload: nil))
                }
            }
            state.index[kind] = entries
            state.scannedKinds.insert(kind)
        }
        self.state = state
        var changes = SyncAppliedChanges()
        for (kind, records) in stale {
            changes.merge(applyLocally(records, of: kind).changes)
        }
        if !changes.isEmpty { onRemoteChanges(changes) }
    }

    /// Settings this device had before its first sync are uploaded only when the server had none and
    /// the user had changed them from the defaults; otherwise a fresh install would overwrite real settings.
    private func claimUnsyncedSettings() {
        guard var state else { return }
        let stamp = SyncStamp(date: now())
        for kind in SyncKind.allCases where kind.isSettings {
            let id = SyncKind.settingsRecordId
            guard let entry = state.index[kind]?[id], entry.updatedAt == nil,
                  let record = local.records(of: kind)[id],
                  record.fingerprint != local.defaultFingerprint(of: kind)
            else { continue }
            state.index[kind]?[id] = SyncIndexEntry(updatedAt: stamp, deleted: false, fingerprint: record.fingerprint)
            state.enqueue(SyncChange(kind: kind.rawValue, id: id, updatedAt: stamp, deleted: false, payload: record.payload))
        }
        self.state = state
    }

    private func exchangeRecords(_ client: SyncClient) async throws {
        var rounds = 0
        while let state, rounds < 10_000 {
            rounds += 1
            let batch = try requestBatch(from: state)
            let response = try await client.sync(SyncRequest(deviceId: state.deviceId.uuidString, cursor: state.cursor, changes: batch))
            self.state?.outbox.removeAll { queued in
                batch.contains { $0.kind == queued.kind && $0.id == queued.id && $0.updatedAt == queued.updatedAt }
            }
            applyRemote(response.changes)
            let cursor = max(response.cursor, self.state?.cursor ?? 0)
            self.state?.cursor = cursor
            save()
            guard response.hasMore || !(self.state?.outbox.isEmpty ?? true) else { return }
        }
    }

    private func requestBatch(from state: SyncState) throws -> [SyncChange] {
        var batch = Array(state.outbox.prefix(recordBatchSize))
        let encoder = JSONEncoder()
        while batch.count > 1,
              try encoder.encode(SyncRequest(deviceId: state.deviceId.uuidString, cursor: state.cursor, changes: batch)).count > SyncClient.maximumBodyBytes * 9 / 10 {
            batch = Array(batch.prefix(batch.count / 2))
        }
        return batch
    }

    private func applyRemote(_ changes: [SyncChange]) {
        guard let state else { return }
        var newest: [SyncKind: [String: SyncChange]] = [:]
        for change in changes {
            guard let kind = SyncKind(rawValue: change.kind) else { continue }
            if let known = state.index[kind]?[change.id]?.updatedAt, change.updatedAt <= known { continue }
            if let seen = newest[kind]?[change.id], seen.updatedAt >= change.updatedAt { continue }
            newest[kind, default: [:]][change.id] = change
        }
        var applied = SyncAppliedChanges()
        for (kind, byId) in newest {
            let records = byId.values.map { RemoteRecord(id: $0.id, payload: $0.deleted ? nil : $0.payload) }
            let result = applyLocally(records, of: kind)
            applied.merge(result.changes)
            for (id, fingerprint) in result.fingerprints {
                guard let change = byId[id] else { continue }
                self.state?.index[kind, default: [:]][id] = SyncIndexEntry(updatedAt: change.updatedAt, deleted: change.deleted, fingerprint: fingerprint)
                self.state?.outbox.removeAll { $0.kind == kind.rawValue && $0.id == id }
            }
        }
        if !applied.isEmpty { onRemoteChanges(applied) }
    }

    private func applyLocally(_ records: [RemoteRecord], of kind: SyncKind) -> (fingerprints: [String: String?], changes: SyncAppliedChanges) {
        if kind == .meal {
            mealsWillChange(records.compactMap { UUID(uuidString: $0.id) })
        }
        let fingerprints = local.apply(records, of: kind)
        var changes = SyncAppliedChanges()
        if !fingerprints.isEmpty {
            switch kind {
            case .meal: changes.meals = Set(fingerprints.keys.compactMap { UUID(uuidString: $0) })
            case .manualDose: changes.history = true
            default: changes.settings = true
            }
        }
        return (fingerprints, changes)
    }

    // MARK: Readings and Glooko Doses

    /// Months whose Reading count matches what was uploaded are skipped; a month that gained
    /// Readings (a late Backfill) is sent again, which the server ignores for what it has.
    private func uploadReadings(_ client: SyncClient) async throws {
        let history = history
        guard let earliest = await Task.detached(operation: { history.earliestReadingDate() }).value else { return }
        for month in MonthKey.covering(earliest...max(earliest, now())) {
            let readings = await Task.detached(operation: { history.readings(in: month.interval) }).value
            let key = month.description
            guard state?.readingsUploaded[key] != readings.count else { continue }
            var progress = state?.readingsProgress
            if progress?.month != key || progress?.countAtStart != readings.count { progress = nil }
            let pending = readings.map(WireReading.init).filter { $0.t > progress?.lastUploaded ?? Int.min }
            for start in stride(from: 0, to: pending.count, by: readingBatchSize) {
                let batch = Array(pending[start..<min(start + readingBatchSize, pending.count)])
                try await client.upload(readings: batch)
                state?.readingsProgress = ReadingsUploadProgress(month: key, lastUploaded: batch.last!.t, countAtStart: readings.count)
                save()
            }
            state?.readingsUploaded[key] = readings.count
            state?.readingsProgress = nil
            save()
        }
    }

    private func uploadGlookoDoses(_ client: SyncClient) async throws {
        let history = history
        let doses = await Task.detached(operation: { history.allDoses().filter { !$0.isManual } }).value
        let byMonth = Dictionary(grouping: doses) { MonthKey($0.timestamp).description }
        for key in byMonth.keys.sorted() {
            let wire = try byMonth[key]!.sorted { $0.id < $1.id }.map(WireDose.init)
            let fingerprint = syncFingerprint(.array(wire.map { .array([.string($0.id), $0.payload]) }))
            guard state?.dosesUploaded[key] != fingerprint else { continue }
            for start in stride(from: 0, to: wire.count, by: 1000) {
                try await client.upload(doses: Array(wire[start..<min(start + 1000, wire.count)]))
            }
            state?.dosesUploaded[key] = fingerprint
            save()
        }
    }

    /// Readings and Doses other devices uploaded: the last 90 days on the first sync, then what came
    /// since, looking back a little (and further once a day) for data uploaded late.
    private func downloadHistory(_ client: SyncClient) async throws {
        guard let state else { return }
        let date = now()
        let nowSeconds = Int(date.timeIntervalSince1970)
        let isDeep = state.lastDeepDownload.map { date.timeIntervalSince($0) >= Self.deepDownloadInterval } ?? true
        let readingsOverlap = isDeep ? Self.deepDownloadOverlap : Self.downloadOverlap
        let firstFrom = nowSeconds - Int(Self.historyDays)
        var changed = false

        let readingsFrom = state.readingsDownloadedThrough.map { $0 - Int(readingsOverlap) } ?? firstFrom
        var after: Int?
        while true {
            let page = try await client.readings(from: readingsFrom, to: nowSeconds + 3600, after: after)
            changed = storeDownloaded(page.readings.map(\.reading)) || changed
            guard page.hasMore == true, let last = page.readings.last?.t, last > after ?? Int.min else { break }
            after = last
        }
        self.state?.readingsDownloadedThrough = nowSeconds
        save()

        let dosesFrom = state.dosesDownloadedThrough.map { $0 - Int(Self.doseDownloadOverlap) } ?? firstFrom
        after = nil
        while true {
            let page = try await client.doses(from: dosesFrom, to: nowSeconds + 3600, after: after)
            let doses = page.doses.compactMap { try? $0.payload.decode(InsulinDose.self) }.filter { !$0.isManual }
            changed = history.append(doses: doses) > 0 || changed
            // `after` is exclusive on whole seconds, so step back one in case a page split a second.
            guard page.hasMore == true, let last = page.doses.last?.t, last - 1 > after ?? Int.min else { break }
            after = last - 1
        }
        self.state?.dosesDownloadedThrough = nowSeconds
        if isDeep { self.state?.lastDeepDownload = date }
        save()
        if changed { onRemoteChanges(SyncAppliedChanges(history: true)) }
    }

    /// Readings from the server are already there, so a month that was fully uploaded stays so.
    private func storeDownloaded(_ readings: [Reading]) -> Bool {
        var changed = false
        for (key, group) in Dictionary(grouping: readings, by: { MonthKey($0.timestamp).description }) {
            let added = history.append(readings: group)
            guard added > 0 else { continue }
            changed = true
            if let uploaded = state?.readingsUploaded[key] { state?.readingsUploaded[key] = uploaded + added }
        }
        return changed
    }
}

extension SyncState {
    mutating func enqueue(_ change: SyncChange) {
        outbox.removeAll { $0.kind == change.kind && $0.id == change.id }
        outbox.append(change)
    }
}

extension SyncAppliedChanges {
    mutating func merge(_ other: SyncAppliedChanges) {
        meals.formUnion(other.meals)
        history = history || other.history
        settings = settings || other.settings
    }
}
