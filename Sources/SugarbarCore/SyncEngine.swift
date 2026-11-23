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
    public var glooko = false

    public init(meals: Set<UUID> = [], history: Bool = false, settings: Bool = false, glooko: Bool = false) {
        self.meals = meals
        self.history = history
        self.settings = settings
        self.glooko = glooko
    }

    public var isEmpty: Bool { meals.isEmpty && !history && !settings && !glooko }
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

    public var glooko: GlookoBridgeInfo {
        (state ?? stateStore.load())?.glooko ?? GlookoBridgeInfo()
    }

    /// Asks the Sync Server to send to Glooko or stop, through a synced `glookoSettings` record.
    /// The time zone lets the server write Glooko's local wall-clock times.
    public func setGlookoSending(_ enabled: Bool, timeZone: TimeZone = .current) {
        guard let configuration = configuration() else { return }
        prepareState(for: configuration)
        guard var state else { return }
        var info = state.glooko ?? GlookoBridgeInfo()
        let settings = GlookoBridgeSettings(enabled: enabled, timeZone: timeZone.identifier)
        let stamp = max(SyncStamp(date: now()), (info.settingsUpdatedAt ?? 0) + 1)
        info.settings = settings
        info.settingsUpdatedAt = stamp
        state.glooko = info
        state.enqueue(SyncChange(kind: GlookoBridgeInfo.settingsKind, id: SyncKind.settingsRecordId, updatedAt: stamp, deleted: false, payload: try? JSONValue(encoding: settings)))
        self.state = state
        save()
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
            if state?.outbox.isEmpty == false { try await exchangeRecords(client) }
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
        var applied = SyncAppliedChanges()
        for change in changes {
            if GlookoBridgeInfo.kinds.contains(change.kind) {
                applied.merge(applyGlooko(change))
                continue
            }
            if change.kind == HistoryRange.kind {
                if !change.id.hasPrefix(state.deviceId.uuidString), let range = try? change.payload?.decode(HistoryRange.self) {
                    self.state?.pendingDownloads.append(range)
                }
                continue
            }
            guard let kind = SyncKind(rawValue: change.kind) else { continue }
            if let known = state.index[kind]?[change.id]?.updatedAt, change.updatedAt <= known { continue }
            if let seen = newest[kind]?[change.id], seen.updatedAt >= change.updatedAt { continue }
            newest[kind, default: [:]][change.id] = change
        }
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

    private func applyGlooko(_ change: SyncChange) -> SyncAppliedChanges {
        var info = state?.glooko ?? GlookoBridgeInfo()
        let before = info
        switch change.kind {
        case GlookoBridgeInfo.settingsKind:
            guard change.updatedAt > (info.settingsUpdatedAt ?? .min) else { return SyncAppliedChanges() }
            info.settingsUpdatedAt = change.updatedAt
            info.settings = change.deleted ? nil : try? change.payload?.decode(GlookoBridgeSettings.self)
        case GlookoBridgeInfo.summaryKind:
            info.summary = change.deleted ? nil : try? change.payload?.decode(GlookoBridgeSummary.self)
        default:
            info.items[change.id] = change.deleted ? nil : try? change.payload?.decode(GlookoItemStatus.self)
        }
        guard info != before else { return SyncAppliedChanges() }
        state?.glooko = info
        var applied = SyncAppliedChanges(glooko: true)
        if info.echoes != before.echoes, info.echoes != history.glookoEchoes() {
            history.setGlookoEchoes(info.echoes)
            applied.history = true
        }
        return applied
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

    /// Uploads each month in time order, remembering how far it got, so a sync sends only new Readings
    /// and a broken upload resumes. A month that gained older Readings (a late Backfill) goes again whole;
    /// the server ignores what it already has.
    private func uploadReadings(_ client: SyncClient) async throws {
        let history = history
        guard let earliest = await Task.detached(operation: { history.earliestReadingDate() }).value else { return }
        let oldBefore = Int(now().addingTimeInterval(-Self.downloadOverlap).timeIntervalSince1970)
        for month in MonthKey.covering(earliest...max(earliest, now())) {
            let readings = await Task.detached(operation: { history.readings(in: month.interval) }).value.map(WireReading.init)
            let key = month.description
            var uploaded = state?.readingsUploaded[key] ?? MonthUpload()
            let alreadyThere = readings.partitioningIndex { $0.t > uploaded.last }
            guard alreadyThere != readings.count || uploaded.count != readings.count else { continue }
            if alreadyThere != uploaded.count { uploaded = MonthUpload() }
            var start = uploaded.count
            while start < readings.count {
                let batch = Array(readings[start..<min(start + readingBatchSize, readings.count)])
                try await client.upload(readings: batch)
                start += batch.count
                uploaded = MonthUpload(count: start, last: batch.last!.t)
                state?.readingsUploaded[key] = uploaded
                announceUpload(of: batch.map(\.t).filter { $0 < oldBefore }, in: key)
                save()
            }
        }
    }

    private func uploadGlookoDoses(_ client: SyncClient) async throws {
        let history = history
        let doses = await Task.detached(operation: { history.allDoses().filter { !$0.isManual } }).value
        let oldBefore = Int(now().addingTimeInterval(-Self.doseDownloadOverlap).timeIntervalSince1970)
        let byMonth = Dictionary(grouping: doses) { MonthKey($0.timestamp).description }
        for key in byMonth.keys.sorted() {
            let wire = try byMonth[key]!.sorted { $0.id < $1.id }.map(WireDose.init)
            let fingerprint = doseMonthFingerprint(wire)
            guard state?.dosesUploaded[key] != fingerprint else { continue }
            for start in stride(from: 0, to: wire.count, by: 1000) {
                try await client.upload(doses: Array(wire[start..<min(start + 1000, wire.count)]))
            }
            state?.dosesUploaded[key] = fingerprint
            announceUpload(of: wire.map(\.t).filter { $0 < oldBefore }, in: key)
            save()
        }
    }

    private func doseMonthFingerprint(_ wire: [WireDose]) -> String {
        syncFingerprint(.array(wire.map { .array([.string($0.id), $0.payload]) }))
    }

    /// Other devices only look back a little for new History, so uploading older data leaves a
    /// `historyUpload` record (one per device and month, its range growing) telling them to fetch it.
    private func announceUpload(of times: [Int], in month: String) {
        guard var state, let first = times.min(), let last = times.max() else { return }
        let previous = state.announced[month]
        let range = HistoryRange(from: min(first, previous?.from ?? first), to: max(last, previous?.to ?? last))
        guard range != previous, let payload = try? JSONValue(encoding: range) else { return }
        state.announced[month] = range
        state.lastAnnouncement = max(SyncStamp(date: now()), state.lastAnnouncement + 1)
        state.enqueue(SyncChange(
            kind: HistoryRange.kind,
            id: "\(state.deviceId.uuidString)/\(month)",
            updatedAt: state.lastAnnouncement,
            deleted: false,
            payload: payload
        ))
        self.state = state
    }

    /// Readings and Doses other devices uploaded: the last 90 days on the first sync, then what came
    /// since with a short overlap (longer once a day), plus every range another device announced.
    private func downloadHistory(_ client: SyncClient) async throws {
        guard let state else { return }
        let date = now()
        let nowSeconds = Int(date.timeIntervalSince1970)
        let isDeep = state.lastDeepDownload.map { date.timeIntervalSince($0) >= Self.deepDownloadInterval } ?? true
        let firstFrom = nowSeconds - Int(Self.historyDays)
        let readingsOverlap = Int(isDeep ? Self.deepDownloadOverlap : Self.downloadOverlap)
        var changed = false

        changed = try await downloadReadings(client, from: state.readingsDownloadedThrough.map { $0 - readingsOverlap } ?? firstFrom, to: nowSeconds + 3600) || changed
        self.state?.readingsDownloadedThrough = nowSeconds
        save()
        changed = try await downloadDoses(client, from: state.dosesDownloadedThrough.map { $0 - Int(Self.doseDownloadOverlap) } ?? firstFrom, to: nowSeconds + 3600) || changed
        self.state?.dosesDownloadedThrough = nowSeconds
        if isDeep { self.state?.lastDeepDownload = date }
        save()

        while let range = self.state?.pendingDownloads.first {
            changed = try await downloadReadings(client, from: range.from, to: range.to) || changed
            changed = try await downloadDoses(client, from: range.from, to: range.to) || changed
            self.state?.pendingDownloads.removeFirst()
            save()
        }
        if changed { onRemoteChanges(SyncAppliedChanges(history: true)) }
    }

    private func downloadReadings(_ client: SyncClient, from: Int, to: Int) async throws -> Bool {
        var changed = false
        var after: Int?
        while true {
            let page = try await client.readings(from: from, to: to, after: after)
            changed = storeDownloaded(page.readings.map(\.reading)) || changed
            guard page.hasMore == true, let last = page.readings.last?.t, last > after ?? Int.min else { return changed }
            after = last
        }
    }

    private func downloadDoses(_ client: SyncClient, from: Int, to: Int) async throws -> Bool {
        var changed = false
        var after: Int?
        while true {
            let page = try await client.doses(from: from, to: to, after: after)
            let doses = page.doses.compactMap { try? $0.payload.decode(InsulinDose.self) }.filter { !$0.isManual }
            changed = storeDownloaded(doses) || changed
            // `after` is exclusive on whole seconds, so step back one in case a page split a second.
            guard page.hasMore == true, let last = page.doses.last?.t, last - 1 > after ?? Int.min else { return changed }
            after = last - 1
        }
    }

    /// What came from the server is on the server: a month that was fully uploaded stays so,
    /// and is neither sent back nor announced again.
    private func storeDownloaded(_ readings: [Reading]) -> Bool {
        var changed = false
        for (month, group) in Dictionary(grouping: readings, by: { MonthKey($0.timestamp) }) {
            let key = month.description
            let before = history.readings(in: month.interval)
            guard history.append(readings: group) > 0 else { continue }
            changed = true
            let uploaded = state?.readingsUploaded[key] ?? MonthUpload()
            if uploaded.count == before.count, (before.last.map { WireReading($0).t } ?? Int.min) == uploaded.last {
                let after = history.readings(in: month.interval)
                state?.readingsUploaded[key] = MonthUpload(count: after.count, last: after.last.map { WireReading($0).t } ?? Int.min)
            }
        }
        return changed
    }

    private func storeDownloaded(_ doses: [InsulinDose]) -> Bool {
        guard !doses.isEmpty else { return false }
        func monthFingerprints() -> [String: String] {
            let all = history.allDoses().filter { !$0.isManual }
            return Dictionary(grouping: all) { MonthKey($0.timestamp).description }
                .compactMapValues { list in (try? list.sorted { $0.id < $1.id }.map(WireDose.init)).map(doseMonthFingerprint) }
        }
        let before = monthFingerprints()
        guard history.append(doses: doses) > 0 else { return false }
        let after = monthFingerprints()
        for key in Set(before.keys).union(after.keys) where state?.dosesUploaded[key] == before[key] {
            state?.dosesUploaded[key] = after[key]
        }
        return true
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
        glooko = glooko || other.glooko
    }
}
