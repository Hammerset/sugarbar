import AsyncHTTPClient
import Foundation
import Logging
import PostgresNIO
import ServiceLifecycle

public struct GlookoBridgeConfiguration: Sendable {
    public var credentialsFile: String?
    public var signInURL: URL
    public var tick: Duration
    /// How often to read Glooko for imports and pen doses.
    public var readInterval: TimeInterval

    public init(credentialsFile: String?, signInURL: URL = glookoSignInURL, tick: Duration = .seconds(5), readInterval: TimeInterval = 300) {
        self.credentialsFile = credentialsFile
        self.signInURL = signInURL
        self.tick = tick
        self.readInterval = readInterval
    }
}

/// The single writer to Glooko. It follows the `records` sequence, pushes eaten Meals and manual
/// Doses, removes a pushed manual Dose once its pen dose is in Glooko, and imports carbs entered
/// in the Glooko app as Meals. Every Sugarbar record maps to one Glooko entry through `glooko_links`,
/// whose row (and Glooko guid) exists before the first write, so a retry can only overwrite it.
actor GlookoBridge: Service {
    static let settingsKind = "glookoSettings"
    static let statusKind = "glookoStatus"
    static let summaryKind = "glookoBridge"
    static let matchTolerance: TimeInterval = 20 * 60
    static let removalLookback: TimeInterval = 3 * 86400
    static let signInRetry: TimeInterval = 30 * 60

    private let db: PostgresClient
    private let logger: Logger
    private let configuration: GlookoBridgeConfiguration
    private let http: HTTPClient
    private let now: @Sendable () -> Date
    private var clients: [Int64: (credentials: GlookoCredentials, client: GlookoClient)] = [:]
    private var lastRead: [Int64: Date] = [:]

    init(db: PostgresClient, configuration: GlookoBridgeConfiguration, http: HTTPClient, logger: Logger, now: @escaping @Sendable () -> Date = Date.init) {
        self.db = db
        self.configuration = configuration
        self.http = http
        self.logger = logger
        self.now = now
    }

    func run() async throws {
        // Services start alongside `beforeServerStarts`, so the tables may not exist yet.
        try await Migrations.run(on: db, logger: logger)
        while !Task.isCancelled && !Task.isShuttingDownGracefully {
            do {
                try await tick()
            } catch {
                logger.error("glooko bridge tick failed", metadata: ["error.type": "\(type(of: error))"])
            }
            let tick = configuration.tick
            try? await cancelWhenGracefulShutdown { try await Task.sleep(for: tick) }
        }
        try? await http.shutdown()
    }

    // MARK: Accounts

    private struct Account {
        let id: Int64
        let name: String
        let enabled: Bool
        let timeZone: TimeZone
        let settingsUpdatedAt: Date?
        var state: State?
    }

    struct State {
        var recordsCursor: Int64
        var pushFrom: Date
        var feed: GlookoFeedCursor
        var pausedReason: String?
        /// The `glookoSettings` version in force when sending was paused; a newer one resumes it.
        var pausedSettingsAt: Date?
        var retryAt: Date?
        var failures: Int
        var summaryFingerprint: String?
    }

    private struct Settings: Decodable {
        var enabled: Bool?
        var timeZone: String?
    }

    func tick(onlyAccount: Int64? = nil) async throws {
        for var account in try await accounts() where onlyAccount == nil || account.id == onlyAccount {
            guard account.enabled || account.state != nil else { continue }
            if account.state == nil { account.state = try await createState(for: account) }
            try await process(&account)
        }
    }

    private func accounts() async throws -> [Account] {
        let rows = try await db.query(
            """
            SELECT a.id, a.name, r.payload::text, r.updated_at, s.account_id IS NOT NULL
            FROM accounts a
            LEFT JOIN records r ON r.account_id = a.id AND r.kind = \(Self.settingsKind) AND r.id = 'default' AND NOT r.deleted
            LEFT JOIN glooko_state s ON s.account_id = a.id
            WHERE r.account_id IS NOT NULL OR s.account_id IS NOT NULL
            ORDER BY a.id
            """,
            logger: logger
        )
        var accounts: [Account] = []
        for try await (id, name, payload, updatedAt, hasState) in rows.decode((Int64, String, String?, Date?, Bool).self) {
            let settings = payload.flatMap { try? JSONDecoder().decode(Settings.self, from: Data($0.utf8)) }
            accounts.append(Account(
                id: id,
                name: name,
                enabled: settings?.enabled ?? false,
                timeZone: settings?.timeZone.flatMap(TimeZone.init(identifier:)) ?? .current,
                settingsUpdatedAt: updatedAt,
                state: hasState ? try await loadState(id) : nil
            ))
        }
        return accounts
    }

    /// From the first time it is switched on, the bridge sends what changes from then on, and
    /// imports carbs entered in Glooko from then on: older entries already live in both places.
    private func createState(for account: Account) async throws -> State {
        let date = now()
        var cursor: Int64 = 0
        for try await seq in try await db.query("SELECT coalesce(max(seq), 0) FROM records WHERE account_id = \(account.id)", logger: logger).decode(Int64.self) {
            cursor = seq
        }
        let state = State(recordsCursor: cursor, pushFrom: date.addingTimeInterval(-86400), feed: .starting(at: date), failures: 0)
        try await db.query(
            """
            INSERT INTO glooko_state (account_id, records_cursor, push_from, feed_updated_at, feed_guid)
            VALUES (\(account.id), \(state.recordsCursor), \(state.pushFrom), \(state.feed.updatedAt), \(state.feed.guid))
            ON CONFLICT (account_id) DO NOTHING
            """,
            logger: logger
        )
        return try await loadState(account.id) ?? state
    }

    private func loadState(_ accountId: Int64) async throws -> State? {
        let rows = try await db.query(
            """
            SELECT records_cursor, push_from, feed_updated_at, feed_guid, paused_reason, paused_settings_at, retry_at, failures, summary_fingerprint
            FROM glooko_state WHERE account_id = \(accountId)
            """,
            logger: logger
        )
        for try await (cursor, pushFrom, feedAt, feedGuid, pausedReason, pausedSettingsAt, retryAt, failures, summary) in rows.decode(
            (Int64, Date, String, String, String?, Date?, Date?, Int32, String?).self
        ) {
            return State(
                recordsCursor: cursor, pushFrom: pushFrom, feed: GlookoFeedCursor(updatedAt: feedAt, guid: feedGuid),
                pausedReason: pausedReason, pausedSettingsAt: pausedSettingsAt, retryAt: retryAt, failures: Int(failures), summaryFingerprint: summary
            )
        }
        return nil
    }

    private func saveState(_ accountId: Int64, _ state: State, on connection: PostgresConnection? = nil) async throws {
        let query: PostgresQuery = """
            UPDATE glooko_state SET records_cursor = \(state.recordsCursor), push_from = \(state.pushFrom),
                feed_updated_at = \(state.feed.updatedAt), feed_guid = \(state.feed.guid),
                paused_reason = \(state.pausedReason), paused_settings_at = \(state.pausedSettingsAt), retry_at = \(state.retryAt),
                failures = \(Int32(state.failures)), summary_fingerprint = \(state.summaryFingerprint)
            WHERE account_id = \(accountId)
            """
        if let connection { try await connection.query(query, logger: logger) } else { try await db.query(query, logger: logger) }
    }

    private func process(_ account: inout Account) async throws {
        guard var state = account.state else { return }
        let wallClock = GlookoWallClock(timeZone: account.timeZone)
        if state.pausedReason != nil, let changed = account.settingsUpdatedAt,
           abs(changed.timeIntervalSince(state.pausedSettingsAt ?? .distantPast)) > 0.001 {
            state.pausedReason = nil
            state.pausedSettingsAt = nil
            state.failures = 0
            state.retryAt = nil
        }
        try await followRecords(account.id, &state, wallClock: wallClock)

        guard account.enabled else {
            return try await finish(account.id, &state, summary: ("off", nil))
        }
        let credentials: GlookoCredentials?
        do {
            credentials = try configuration.credentialsFile.map(GlookoCredentialsFile.init(path:))?.load()[account.name]
        } catch {
            return try await finish(account.id, &state, summary: ("noLogin", "The Glooko login file on the server cannot be read"))
        }
        guard let credentials else {
            return try await finish(account.id, &state, summary: ("noLogin", "Set the Glooko login on the server: sugarbar-server set-glooko \(account.name) <email>"))
        }
        if let reason = state.pausedReason {
            return try await finish(account.id, &state, summary: ("paused", reason))
        }
        if let retryAt = state.retryAt, retryAt > now() { return try await saveState(account.id, state) }

        let client = client(for: account.id, credentials: credentials)
        var summary: (String, String?) = ("ok", nil)
        do {
            try await push(account.id, client: client, wallClock: wallClock)
            if lastRead[account.id].map({ now().timeIntervalSince($0) >= configuration.readInterval }) ?? true {
                try await removeSuperseded(account.id, client: client, wallClock: wallClock)
                try await push(account.id, client: client, wallClock: wallClock)
                try await importFoods(account.id, &state, client: client, wallClock: wallClock)
                lastRead[account.id] = now()
            }
            state.failures = 0
            state.retryAt = nil
        } catch let error as GlookoError {
            logger.warning("glooko bridge", metadata: ["account": "\(account.id)", "error": "\(error.message)"])
            switch error {
            case .signInFailed:
                clients[account.id] = nil
                state.retryAt = now().addingTimeInterval(Self.signInRetry)
                summary = ("signInFailed", error.message)
            case .transient:
                state.failures += 1
                state.retryAt = now().addingTimeInterval(Self.backoff(attempts: state.failures))
                summary = ("retrying", error.message)
            case .refused, .unexpected, .sessionExpired, .rejected:
                state.pausedReason = error.message + ". Sending is paused; switch Send to Glooko off and on to try again."
                state.pausedSettingsAt = account.settingsUpdatedAt
                summary = ("paused", state.pausedReason)
            }
        }
        try await finish(account.id, &state, summary: summary)
    }

    private func finish(_ accountId: Int64, _ state: inout State, summary: (state: String, message: String?)) async throws {
        var payload: [String: JSONValue] = ["state": .string(summary.state)]
        if let message = summary.message { payload["message"] = .string(message) }
        let fingerprint = GlookoItems.fingerprint(payload)
        guard fingerprint != state.summaryFingerprint else { return try await saveState(accountId, state) }
        state.summaryFingerprint = fingerprint
        var batch = RecordBatch()
        try batch.append(kind: Self.summaryKind, id: "status", updatedAt: now(), deleted: false, payload: .object(payload))
        let saved = state
        try await db.withTransaction(logger: logger) { connection in
            try await Records.store(batch, accountId: accountId, on: connection, logger: self.logger, serverWrite: true)
            try await self.saveState(accountId, saved, on: connection)
        }
    }

    private func client(for accountId: Int64, credentials: GlookoCredentials) -> GlookoClient {
        if let cached = clients[accountId], cached.credentials == credentials { return cached.client }
        let client = GlookoClient(credentials: credentials, signInURL: configuration.signInURL, http: http)
        clients[accountId] = (credentials, client)
        return client
    }

    static func backoff(attempts: Int) -> TimeInterval {
        min(30 * pow(2, Double(max(0, attempts - 1))), 3600)
    }

    // MARK: Following Sugarbar's records

    private func followRecords(_ accountId: Int64, _ state: inout State, wallClock: GlookoWallClock) async throws {
        while true {
            let rows = try await db.query(
                """
                SELECT seq, kind, id, deleted, payload::text FROM records
                WHERE account_id = \(accountId) AND seq > \(state.recordsCursor) AND kind IN ('meal', 'manualDose')
                ORDER BY seq LIMIT 200
                """,
                logger: logger
            )
            var changes: [(seq: Int64, kind: String, id: String, payload: JSONValue?)] = []
            for try await (seq, kind, id, deleted, payload) in rows.decode((Int64, String, String, Bool, String).self) {
                changes.append((seq, kind, id, deleted ? nil : try? JSONDecoder().decode(JSONValue.self, from: Data(payload.utf8))))
            }
            guard let last = changes.last?.seq else { return }
            state.recordsCursor = last
            let saved = state
            try await db.withTransaction(logger: logger) { connection in
                var statuses = RecordBatch()
                for change in changes {
                    var link = try await self.link(accountId, sourceKind: change.kind, sourceId: change.id, on: connection)
                    let guid = link?.guid ?? GlookoItems.guid(for: change.kind, id: change.id)
                    let wanted = GlookoItems.item(
                        sourceKind: change.kind, payload: change.payload, guid: guid,
                        mealGuid: link?.desired.fields["mealGuid"]?.stringValue, wallClock: wallClock
                    )
                    let isNew = link == nil
                    if isNew {
                        guard let wanted, wanted.eventAt >= saved.pushFrom else { continue }
                        link = GlookoLink(sourceKind: change.kind, sourceId: change.id, guid: guid, origin: "sugarbar", desired: wanted, eventAt: wanted.eventAt)
                    }
                    guard var current = link else { continue }
                    let next = current.removalReason != nil ? current.desired.deleted() : (wanted ?? current.desired.deleted())
                    if !isNew && next.fingerprint == current.desiredFingerprint { continue }
                    current.desired = next
                    current.eventAt = next.eventAt
                    current.markDirty(at: self.now())
                    if !current.isDirty { current.status = next.isDeleted ? (current.removalReason != nil ? "removed" : "deleted") : "sent" }
                    try await self.save(accountId, &current, statuses: &statuses, on: connection)
                }
                try await Records.store(statuses, accountId: accountId, on: connection, logger: self.logger, serverWrite: true)
                try await self.saveState(accountId, saved, on: connection)
            }
        }
    }

    // MARK: Pushing

    private func push(_ accountId: Int64, client: GlookoClient, wallClock: GlookoWallClock) async throws {
        for _ in 0..<50 {
            let due = try await links(
                """
                WHERE account_id = \(accountId) AND desired_fingerprint IS DISTINCT FROM pushed_fingerprint
                    AND status <> 'failed' AND next_attempt_at <= \(now())
                ORDER BY next_attempt_at, source_id LIMIT 50
                """
            )
            guard !due.isEmpty else { return }
            for var link in due {
                if link.desired.isDeleted && !link.written {
                    link.pushedFingerprint = link.desiredFingerprint
                    link.status = link.removalReason != nil ? "removed" : "deleted"
                    try await saveAndPublish(accountId, &link)
                    continue
                }
                if !link.written {
                    link.written = true
                    try await saveAndPublish(accountId, &link)
                }
                let fingerprint = link.desiredFingerprint
                do {
                    try await client.put(collection: link.collection, items: [GlookoItems.wire(link.desired, now: now())])
                } catch let error as GlookoError {
                    link.lastError = error.message
                    link.attempts += 1
                    if case .rejected = error {
                        link.status = "failed"
                        try await saveAndPublish(accountId, &link)
                        continue
                    }
                    link.nextAttemptAt = now().addingTimeInterval(Self.backoff(attempts: link.attempts))
                    try await saveAndPublish(accountId, &link)
                    throw error
                }
                link.pushedFingerprint = fingerprint
                link.attempts = 0
                link.lastError = nil
                link.status = link.desired.isDeleted ? (link.removalReason != nil ? "removed" : "deleted") : "sent"
                if link.sourceKind == GlookoItems.manualDoseKind, !link.desired.isDeleted {
                    link.addEcho()
                }
                try await saveAndPublish(accountId, &link)
            }
        }
    }

    // MARK: Pen doses superseding manual ones

    /// Same rule as the apps' `reconcileDoses`: same kind, units within 0.01, at most 20 minutes
    /// apart, closest pairs first, each pen dose used once.
    private func removeSuperseded(_ accountId: Int64, client: GlookoClient, wallClock: GlookoWallClock) async throws {
        let live = try await links(
            """
            WHERE account_id = \(accountId) AND source_kind = 'manualDose' AND origin = 'sugarbar' AND removal_reason IS NULL
                AND (desired->>'softDeleted')::boolean = false AND event_at > \(now().addingTimeInterval(-Self.removalLookback))
            """
        )
        guard let earliest = live.map(\.eventAt).min(), let latest = live.map(\.eventAt).max() else { return }
        var used = Set<String>()
        for try await key in try await db.query(
            "SELECT superseded_by FROM glooko_links WHERE account_id = \(accountId) AND superseded_by IS NOT NULL",
            logger: logger
        ).decode(String.self) {
            used.insert(key)
        }
        let graph = try await client.graphInsulin(
            from: wallClock.format(earliest.addingTimeInterval(-Self.matchTolerance)),
            to: wallClock.format(latest.addingTimeInterval(Self.matchTolerance))
        )
        let penDoses = ([("bolus", graph.bolus), ("basal", graph.basal)] as [(String, [GlookoGraphDose])]).flatMap { kind, doses in
            doses.compactMap { dose -> (key: String, kind: String, units: Double, at: Date)? in
                guard dose.isFromPen, let units = dose.value, let timestamp = dose.timestamp, let at = wallClock.parse(timestamp) else { return nil }
                return ("\(kind)|\(timestamp)|\(units)", kind, units, at)
            }
        }.filter { !used.contains($0.key) }

        var candidates: [(link: Int, pen: Int, gap: TimeInterval)] = []
        for (linkIndex, link) in live.enumerated() {
            for (penIndex, pen) in penDoses.enumerated() {
                let gap = abs(pen.at.timeIntervalSince(link.eventAt))
                guard link.desired.fields["insulinType"]?.stringValue == pen.kind,
                      let units = link.desired.fields["value"]?.doubleValue, abs(units - pen.units) < 0.01,
                      gap <= Self.matchTolerance
                else { continue }
                candidates.append((linkIndex, penIndex, gap))
            }
        }
        var pairedLinks = Set<Int>(), pairedPens = Set<Int>()
        for pair in candidates.sorted(by: { $0.gap < $1.gap }) where !pairedLinks.contains(pair.link) && !pairedPens.contains(pair.pen) {
            pairedLinks.insert(pair.link)
            pairedPens.insert(pair.pen)
            var link = live[pair.link]
            let pen = penDoses[pair.pen]
            link.removalReason = "Pen dose of \(Self.formatUnits(pen.units)) U at \(wallClock.clockTime(pen.at)) arrived in Glooko"
            link.supersededBy = pen.key
            link.desired = link.desired.deleted()
            link.markDirty(at: now())
            try await saveAndPublish(accountId, &link)
        }
    }

    static func formatUnits(_ units: Double) -> String {
        units == units.rounded() ? String(format: "%.0f", units) : String(format: "%.1f", units)
    }

    // MARK: Importing carbs entered in Glooko

    private func importFoods(_ accountId: Int64, _ state: inout State, client: GlookoClient, wallClock: GlookoWallClock) async throws {
        for _ in 0..<100 {
            let page = try await client.foods(after: state.feed)
            if let updatedAt = page.lastUpdatedAt, let guid = page.lastGuid {
                state.feed = GlookoFeedCursor(updatedAt: updatedAt, guid: guid)
            }
            let saved = state
            try await db.withTransaction(logger: logger) { connection in
                var batch = RecordBatch()
                for food in page.foods {
                    try await self.importFood(accountId, food, wallClock: wallClock, batch: &batch, on: connection)
                }
                try await Records.store(batch, accountId: accountId, on: connection, logger: self.logger, serverWrite: true)
                try await self.saveState(accountId, saved, on: connection)
            }
            if page.lastPage || page.foods.isEmpty { return }
        }
    }

    private func importFood(_ accountId: Int64, _ food: GlookoFood, wallClock: GlookoWallClock, batch: inout RecordBatch, on connection: PostgresConnection) async throws {
        let date = now()
        let remote = GlookoItems.remoteFingerprint(food)
        if var link = try await link(accountId, collection: "foods", guid: food.guid, on: connection) {
            // Sugarbar's own entries come back through the feed; Sugarbar stays their source.
            guard link.origin == "glooko", link.remoteFingerprint != remote else { return }
            link.remoteFingerprint = remote
            if food.softDeleted == true {
                try batch.append(kind: GlookoItems.mealKind, id: link.sourceId, updatedAt: date, deleted: true, payload: .object([:]))
                link.desired = link.desired.deleted()
                link.status = "deleted"
            } else {
                guard let id = UUID(uuidString: link.sourceId),
                      let payload = GlookoItems.mealPayload(id: id, food: food, wallClock: wallClock),
                      let item = GlookoItems.item(sourceKind: GlookoItems.mealKind, payload: payload, guid: link.guid, mealGuid: link.desired.fields["mealGuid"]?.stringValue, wallClock: wallClock)
                else { return }
                try batch.append(kind: GlookoItems.mealKind, id: link.sourceId, updatedAt: date, deleted: false, payload: payload)
                link.desired = item
                link.eventAt = item.eventAt
                link.status = "imported"
            }
            link.desiredFingerprint = link.desired.fingerprint
            link.pushedFingerprint = link.desiredFingerprint
            try await save(accountId, &link, statuses: &batch, on: connection)
            return
        }
        guard food.softDeleted != true else { return }
        let id = UUID()
        guard let payload = GlookoItems.mealPayload(id: id, food: food, wallClock: wallClock),
              let item = GlookoItems.item(sourceKind: GlookoItems.mealKind, payload: payload, guid: food.guid, mealGuid: nil, wallClock: wallClock)
        else { return }
        try batch.append(kind: GlookoItems.mealKind, id: id.uuidString, updatedAt: date, deleted: false, payload: payload)
        var link = GlookoLink(sourceKind: GlookoItems.mealKind, sourceId: id.uuidString, guid: food.guid, origin: "glooko", desired: item, eventAt: item.eventAt)
        link.pushedFingerprint = link.desiredFingerprint
        link.remoteFingerprint = remote
        link.written = true
        link.status = "imported"
        try await save(accountId, &link, statuses: &batch, on: connection)
    }

    // MARK: Link rows

    private func link(_ accountId: Int64, sourceKind: String, sourceId: String, on connection: PostgresConnection) async throws -> GlookoLink? {
        try await GlookoLink.select(
            "WHERE account_id = \(accountId) AND source_kind = \(sourceKind) AND source_id = \(sourceId)",
            on: connection, logger: logger
        ).first
    }

    private func link(_ accountId: Int64, collection: String, guid: String, on connection: PostgresConnection) async throws -> GlookoLink? {
        try await GlookoLink.select(
            "WHERE account_id = \(accountId) AND collection = \(collection) AND glooko_guid = \(guid)",
            on: connection, logger: logger
        ).first
    }

    private func links(_ condition: PostgresQuery) async throws -> [GlookoLink] {
        try await db.withConnection { connection in
            try await GlookoLink.select(condition, on: connection, logger: self.logger)
        }
    }

    private func saveAndPublish(_ accountId: Int64, _ link: inout GlookoLink) async throws {
        var copy = link
        try await db.withTransaction(logger: logger) { connection in
            var statuses = RecordBatch()
            try await self.save(accountId, &copy, statuses: &statuses, on: connection)
            try await Records.store(statuses, accountId: accountId, on: connection, logger: self.logger, serverWrite: true)
        }
        link = copy
    }

    /// Writes the link and, when what the apps should show changed, its `glookoStatus` record.
    private func save(_ accountId: Int64, _ link: inout GlookoLink, statuses: inout RecordBatch, on connection: PostgresConnection) async throws {
        let status = link.statusPayload
        let fingerprint = GlookoItems.fingerprint(status)
        if fingerprint != link.statusFingerprint {
            link.statusFingerprint = fingerprint
            try statuses.append(kind: Self.statusKind, id: "\(link.sourceKind)/\(link.sourceId)", updatedAt: now(), deleted: false, payload: .object(status))
        }
        try await link.upsert(accountId: accountId, on: connection, logger: logger)
    }
}

struct GlookoLink {
    var sourceKind: String
    var sourceId: String
    var collection: String
    var guid: String
    var origin: String
    var desired: GlookoItem
    var desiredFingerprint: String
    var pushedFingerprint: String?
    var remoteFingerprint: String?
    var written = false
    var status = "pending"
    var lastError: String?
    var attempts = 0
    var nextAttemptAt = Date(timeIntervalSince1970: 0)
    var eventAt: Date
    var removalReason: String?
    var supersededBy: String?
    var echoes: [JSONValue] = []
    var statusFingerprint: String?

    init(sourceKind: String, sourceId: String, guid: String, origin: String, desired: GlookoItem, eventAt: Date) {
        self.sourceKind = sourceKind
        self.sourceId = sourceId
        self.collection = GlookoItems.collection(for: sourceKind)
        self.guid = guid
        self.origin = origin
        self.desired = desired
        self.desiredFingerprint = desired.fingerprint
        self.eventAt = eventAt
    }

    var isDirty: Bool { desiredFingerprint != pushedFingerprint }

    mutating func markDirty(at date: Date) {
        desiredFingerprint = desired.fingerprint
        guard isDirty else { return }
        status = "pending"
        attempts = 0
        lastError = nil
        nextAttemptAt = date
    }

    /// Every version written to Glooko, so the apps can tell a Glooko read of it from a real dose.
    mutating func addEcho() {
        guard let kind = desired.fields["insulinType"], let units = desired.fields["value"] else { return }
        let echo = JSONValue.object(["kind": kind, "units": units, "t": .int(Int64(eventAt.timeIntervalSince1970.rounded(.down)))])
        if !echoes.contains(echo) { echoes.append(echo) }
    }

    var statusPayload: [String: JSONValue] {
        let state: String = switch status {
        case "pending": "waiting"
        default: status
        }
        var payload: [String: JSONValue] = ["state": .string(state), "glookoId": .string(guid)]
        if let message = status == "removed" ? removalReason : lastError { payload["message"] = .string(message) }
        if sourceKind == GlookoItems.manualDoseKind { payload["echoes"] = .array(echoes) }
        return payload
    }

    private struct Row: Decodable {
        let source_kind: String
        let source_id: String
        let glooko_guid: String
        let origin: String
        let desired: [String: JSONValue]
        let desired_fingerprint: String
        let pushed_fingerprint: String?
        let remote_fingerprint: String?
        let written: Bool
        let status: String
        let last_error: String?
        let attempts: Int
        let next_attempt_epoch: Double
        let event_epoch: Double
        let removal_reason: String?
        let superseded_by: String?
        let echoes: [JSONValue]
        let status_fingerprint: String?
    }

    static func select(_ condition: PostgresQuery, on connection: PostgresConnection, logger: Logger) async throws -> [GlookoLink] {
        let query = PostgresQuery(
            unsafeSQL: """
                SELECT row_to_json(l)::text FROM (
                    SELECT source_kind, source_id, glooko_guid, origin, desired, desired_fingerprint, pushed_fingerprint,
                        remote_fingerprint, written, status, last_error, attempts,
                        next_attempt_at, event_at,
                        extract(epoch FROM next_attempt_at)::float8 AS next_attempt_epoch, extract(epoch FROM event_at)::float8 AS event_epoch,
                        removal_reason, superseded_by, echoes, status_fingerprint, account_id, collection
                    FROM glooko_links
                ) l
                """ + " " + condition.sql,
            binds: condition.binds
        )
        var links: [GlookoLink] = []
        for try await text in try await connection.query(query, logger: logger).decode(String.self) {
            let row = try JSONDecoder().decode(Row.self, from: Data(text.utf8))
            let eventAt = Date(timeIntervalSince1970: row.event_epoch)
            var link = GlookoLink(
                sourceKind: row.source_kind, sourceId: row.source_id, guid: row.glooko_guid, origin: row.origin,
                desired: GlookoItem(fields: row.desired, eventAt: eventAt), eventAt: eventAt
            )
            link.desiredFingerprint = row.desired_fingerprint
            link.pushedFingerprint = row.pushed_fingerprint
            link.remoteFingerprint = row.remote_fingerprint
            link.written = row.written
            link.status = row.status
            link.lastError = row.last_error
            link.attempts = row.attempts
            link.nextAttemptAt = Date(timeIntervalSince1970: row.next_attempt_epoch)
            link.removalReason = row.removal_reason
            link.supersededBy = row.superseded_by
            link.echoes = row.echoes
            link.statusFingerprint = row.status_fingerprint
            links.append(link)
        }
        return links
    }

    func upsert(accountId: Int64, on connection: PostgresConnection, logger: Logger) async throws {
        let desiredText = String(decoding: try JSONEncoder().encode(JSONValue.object(desired.fields)), as: UTF8.self)
        let echoesText = String(decoding: try JSONEncoder().encode(echoes), as: UTF8.self)
        try await connection.query(
            """
            INSERT INTO glooko_links (account_id, source_kind, source_id, collection, glooko_guid, origin, desired, desired_fingerprint,
                pushed_fingerprint, remote_fingerprint, written, status, last_error, attempts, next_attempt_at, event_at,
                removal_reason, superseded_by, echoes, status_fingerprint)
            VALUES (\(accountId), \(sourceKind), \(sourceId), \(collection), \(guid), \(origin), \(desiredText)::jsonb, \(desiredFingerprint),
                \(pushedFingerprint), \(remoteFingerprint), \(written), \(status), \(lastError), \(Int32(attempts)), \(nextAttemptAt), \(eventAt),
                \(removalReason), \(supersededBy), \(echoesText)::jsonb, \(statusFingerprint))
            ON CONFLICT (account_id, source_kind, source_id) DO UPDATE SET
                desired = excluded.desired, desired_fingerprint = excluded.desired_fingerprint,
                pushed_fingerprint = excluded.pushed_fingerprint, remote_fingerprint = excluded.remote_fingerprint,
                written = excluded.written, status = excluded.status, last_error = excluded.last_error,
                attempts = excluded.attempts, next_attempt_at = excluded.next_attempt_at, event_at = excluded.event_at,
                removal_reason = excluded.removal_reason, superseded_by = excluded.superseded_by,
                echoes = excluded.echoes, status_fingerprint = excluded.status_fingerprint
            """,
            logger: logger
        )
    }
}
