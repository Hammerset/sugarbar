import Foundation

/// The kinds of record this app syncs through `POST /v1/sync`.
public enum SyncKind: String, CaseIterable, Codable, Sendable {
    case meal
    case manualDose
    case thresholds
    case therapy
    case dosing
    case alerts
    case therapyLearning

    var isSettings: Bool { self != .meal && self != .manualDose }

    static let settingsRecordId = "default"
}

/// What this device last knew about one record. A deleted entry is a tombstone: never shown, but it
/// keeps a stale local copy from coming back and a late older change from overwriting a newer one.
struct SyncIndexEntry: Codable, Equatable, Sendable {
    /// Nil for a settings section the server has never had: the server's copy wins whenever one arrives.
    var updatedAt: SyncStamp?
    var deleted: Bool
    /// Canonical fingerprint of the local copy, to notice local edits.
    var fingerprint: String?
}

/// The first `count` Readings of a month, up to `last`, are on the server.
struct MonthUpload: Codable, Equatable, Sendable {
    var count = 0
    var last = Int.min
}

/// Epoch seconds, inclusive: History another device uploaded late.
struct HistoryRange: Codable, Equatable, Sendable {
    static let kind = "historyUpload"
    var from: Int
    var to: Int
}

/// Everything the engine must remember between launches, written atomically as one file so an
/// app kill can never leave the outbox and the index disagreeing.
public struct SyncState: Codable, Equatable, Sendable {
    var serverURL: String
    var deviceId: UUID
    var cursor: Int64 = 0
    var index: [SyncKind: [String: SyncIndexEntry]] = [:]
    /// At most one change per record: a newer local change replaces a queued one.
    var outbox: [SyncChange] = []
    var scannedKinds: Set<SyncKind> = []
    var hasPulledEverything = false
    var readingsUploaded: [String: MonthUpload] = [:]
    var announced: [String: HistoryRange] = [:]
    var lastAnnouncement: SyncStamp = 0
    var pendingDownloads: [HistoryRange] = []
    var readingsDownloadedThrough: Int?
    var dosesUploaded: [String: String] = [:]
    var dosesDownloadedThrough: Int?
    var lastDeepDownload: Date?
    var glooko: GlookoBridgeInfo?
    public internal(set) var lastSync: Date?
    public internal(set) var lastError: String?

    init(serverURL: String, deviceId: UUID = UUID()) {
        self.serverURL = serverURL
        self.deviceId = deviceId
    }

    public var pendingCount: Int { outbox.count }
}

public protocol SyncStateStore: Sendable {
    func load() -> SyncState?
    func save(_ state: SyncState)
}

public final class FileSyncStateStore: SyncStateStore, @unchecked Sendable {
    private let file: URL

    public init(file: URL = FileSyncStateStore.defaultFile()) {
        self.file = file
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    /// Per app, not in the App Group: each device keeps its own place in the sync.
    public static func defaultFile() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appending(path: "Sugarbar/Sync/state.json")
    }

    public func load() -> SyncState? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(SyncState.self, from: data)
    }

    public func save(_ state: SyncState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: file, options: .atomic)
    }
}

public final class InMemorySyncStateStore: SyncStateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var state: SyncState?

    public init() {}

    public func load() -> SyncState? { lock.withLock { state } }
    public func save(_ state: SyncState) { lock.withLock { self.state = state } }
}
