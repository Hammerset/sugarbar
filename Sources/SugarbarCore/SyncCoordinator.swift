import Foundation
import Observation

/// Seconds before retrying after the n-th failure in a row: 30 s doubling, at most 30 minutes.
public func syncRetryDelay(afterFailures failures: Int) -> TimeInterval {
    min(30 * pow(2, Double(max(0, failures - 1))), 30 * 60)
}

/// Decides when the engine runs: shortly after a local change, after a successful poll at most every
/// few minutes, on launch and foreground, and on demand. Never more than one sync at a time, and
/// automatic attempts back off after failures.
@MainActor
@Observable
public final class SyncCoordinator {
    public private(set) var status: SyncStatus
    public private(set) var isSyncing = false

    @ObservationIgnored private let engine: SyncEngine
    @ObservationIgnored private let isConfigured: () -> Bool
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let pollInterval: TimeInterval
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var rerun = false
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var retryAt: Date?
    @ObservationIgnored private var lastAttempt: Date?

    public init(
        engine: SyncEngine,
        isConfigured: @escaping () -> Bool,
        now: @escaping () -> Date = Date.init,
        debounce: Duration = .seconds(3),
        pollInterval: TimeInterval = 5 * 60
    ) {
        self.engine = engine
        self.isConfigured = isConfigured
        self.now = now
        self.debounce = debounce
        self.pollInterval = pollInterval
        self.status = engine.status
    }

    public var isEnabled: Bool { isConfigured() }

    public func localChangeHappened() {
        guard isConfigured() else { return }
        engine.recordLocalChanges()
        status = engine.status
        schedule(after: debounce)
    }

    public func pollSucceeded() {
        if let lastAttempt, now().timeIntervalSince(lastAttempt) < pollInterval { return }
        request(force: false)
    }

    public func appBecameActive() {
        request(force: false)
    }

    public func syncNow() {
        request(force: true)
    }

    public func configurationChanged() {
        failures = 0
        retryAt = nil
        status = engine.status
        request(force: true)
    }

    private func schedule(after delay: Duration) {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.request(force: false)
        }
    }

    private func request(force: Bool) {
        guard isConfigured() else { return }
        if !force, let retryAt, now() < retryAt { return }
        if isSyncing {
            rerun = true
            return
        }
        isSyncing = true
        lastAttempt = now()
        Task { await run() }
    }

    private func run() async {
        repeat {
            rerun = false
            do {
                try await engine.sync()
                failures = 0
                retryAt = nil
            } catch {
                logDiagnostic("sync", error)
                failures += 1
                let delay = syncRetryDelay(afterFailures: failures)
                retryAt = now().addingTimeInterval(delay)
                schedule(after: .seconds(delay))
                rerun = false
            }
            status = engine.status
        } while rerun
        isSyncing = false
    }
}

public let syncKeychainServicePrefix = "no.ignite.sugarbar.sync"

/// Where this app's Sync Server is and whether to use it. Per app and per device: the access token
/// lives in this app's Keychain and is never synced or logged.
public final class SyncSettingsStore: @unchecked Sendable {
    private enum Key {
        static let serverURL = "sync.serverURL"
        static let isEnabled = "sync.enabled"
    }

    private let defaults: UserDefaults
    private let tokenStore: CredentialStore

    public init(defaults: UserDefaults = .standard, tokenStore: CredentialStore = KeychainStore(servicePrefix: syncKeychainServicePrefix)) {
        self.defaults = defaults
        self.tokenStore = tokenStore
    }

    public var serverURLText: String { defaults.string(forKey: Key.serverURL) ?? "" }
    public var isEnabled: Bool { defaults.bool(forKey: Key.isEnabled) }
    public var hasToken: Bool { ((try? tokenStore.loadToken()) ?? nil)?.isEmpty == false }

    /// Saves the address and, when given, a new token, and turns sync on.
    public func save(serverURL: URL, token: String?) throws {
        if let token { try tokenStore.saveToken(token) }
        defaults.set(serverURL.absoluteString, forKey: Key.serverURL)
        defaults.set(true, forKey: Key.isEnabled)
    }

    public func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Key.isEnabled)
    }

    public func configuration() -> SyncConfiguration? {
        guard isEnabled,
              let url = SyncConfiguration.serverURL(from: serverURLText),
              let token = (try? tokenStore.loadToken()) ?? nil, !token.isEmpty
        else { return nil }
        return SyncConfiguration(serverURL: url, token: token)
    }
}

/// "Last synced 2 min ago · 3 changes waiting", or why the last attempt failed.
public func syncStatusLine(_ status: SyncStatus, isSyncing: Bool, now: Date) -> String {
    var parts: [String] = []
    if isSyncing {
        parts.append("Syncing…")
    } else if let lastSync = status.lastSync {
        parts.append("Last synced \(formatAge(now.timeIntervalSince(lastSync)))")
    } else {
        parts.append("Not synced yet")
    }
    if status.pendingCount > 0 {
        parts.append("\(status.pendingCount) change\(status.pendingCount == 1 ? "" : "s") waiting")
    }
    return parts.joined(separator: " · ")
}
