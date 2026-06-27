import Foundation
import Observation
import SugarbarCore

@MainActor
@Observable
final class BarViewModel {
    private(set) var latest: Reading?
    private(set) var history: [Reading] = []
    private(set) var statusMessage: String?
    private(set) var now = Date()
    private(set) var settings: Settings
    private(set) var availableConnections: [Connection] = []

    private let credentialStore: CredentialStore
    private let settingsStore: SettingsStore
    private let makeClient: () -> LibreLinkUpClient
    private var engine: PollingEngine?

    init(
        credentialStore: CredentialStore = KeychainStore(),
        settingsStore: SettingsStore = UserDefaultsSettingsStore(),
        makeClient: @escaping () -> LibreLinkUpClient = { LibreLinkUpClient(transport: URLSessionTransport()) }
    ) {
        self.credentialStore = credentialStore
        self.settingsStore = settingsStore
        self.makeClient = makeClient
        self.settings = settingsStore.load()
    }

    var thresholds: Thresholds { settings.thresholds }

    var displayValue: String {
        guard let latest else { return "—" }
        return formatMmolPerL(latest.value)
    }

    var band: Band? {
        latest.map { Band(mmolPerL: $0.value, thresholds: settings.thresholds) }
    }

    var isStale: Bool {
        latest?.isStale(at: now) ?? false
    }

    var trendSymbolName: String? {
        isStale ? nil : latest?.trend.symbolName
    }

    var accountEmail: String? {
        resolveCredentials()?.email
    }

    var needsDisclaimer: Bool {
        !settings.disclaimerAcknowledged
    }

    func chartSeries(window: HistoryWindow) -> [Reading] {
        guard let latest else {
            return readings(history, within: window, of: now)
        }
        return readings(mergeReadings(history: history, latest: latest), within: window, of: now)
    }

    func start() {
        guard engine == nil else { return }
        startEngine()
    }

    func pause() {
        guard let engine else { return }
        Task { await engine.stop() }
    }

    func resume() {
        guard let engine else { return }
        Task { await engine.start() }
    }

    func applySettings(_ newSettings: Settings) {
        let needsRestart = newSettings.pollCadence != settings.pollCadence
            || newSettings.selectedPatientId != settings.selectedPatientId
        settings = newSettings
        settingsStore.save(newSettings)
        if needsRestart { restart() }
    }

    func acknowledgeDisclaimer() {
        var updated = settings
        updated.disclaimerAcknowledged = true
        applySettings(updated)
    }

    func saveCredentials(_ credentials: Credentials) {
        try? credentialStore.saveCredentials(credentials)
        try? credentialStore.clearToken()
        availableConnections = []
        statusMessage = nil
        restart()
    }

    func signOut() {
        try? credentialStore.clearCredentials()
        try? credentialStore.clearToken()
        latest = nil
        history = []
        availableConnections = []
        statusMessage = "Open Settings to sign in"
    }

    func loadConnections() async throws -> [Connection] {
        guard let credentials = resolveCredentials() else {
            throw LibreLinkUpError.authenticationFailed
        }
        let connections = try await makeClient().connections(
            email: credentials.email,
            password: credentials.password
        )
        availableConnections = connections
        return connections
    }

    @discardableResult
    func pollOnce() async -> PollOutcome {
        now = Date()
        guard let credentials = resolveCredentials() else {
            statusMessage = "Open Settings to sign in"
            return .transientFailure
        }
        do {
            let snapshot = try await makeClient().fetchGraph(
                email: credentials.email,
                password: credentials.password,
                preferredPatientId: settings.selectedPatientId
            )
            latest = snapshot.latest
            history = snapshot.history
            statusMessage = nil
            return .success(readingAt: snapshot.latest.timestamp)
        } catch LibreLinkUpError.rateLimited {
            statusMessage = "Rate limited — backing off"
            return .rateLimited
        } catch LibreLinkUpError.termsNotAccepted {
            statusMessage = "Open the LibreLinkUp app and re-accept the terms"
            return .transientFailure
        } catch {
            statusMessage = String(describing: error)
            return .transientFailure
        }
    }

    private func startEngine() {
        let engine = PollingEngine(planner: PollPlanner(cadence: settings.pollCadence)) { [weak self] in
            await self?.pollOnce() ?? .transientFailure
        }
        self.engine = engine
        Task { await engine.start() }
    }

    private func restart() {
        if let engine { Task { await engine.stop() } }
        engine = nil
        startEngine()
    }

    private func resolveCredentials() -> Credentials? {
        Credentials.fromEnvironment() ?? (try? credentialStore.loadCredentials())
    }
}
