import Foundation
import Observation
import SugarbarCore
import SugarbarUI

@MainActor
@Observable
final class BarViewModel {
    private(set) var latest: Reading?
    private(set) var sensorActivation: Date?
    private(set) var statusMessage: String?
    private(set) var now = Date()
    private(set) var settings: Settings
    private(set) var availableConnections: [Connection] = []
    private(set) var insulinSyncError: String?
    private(set) var meals: [Meal] = []
    private(set) var forecast: Forecast?

    private let credentialStore: CredentialStore
    private let glookoCredentialStore: CredentialStore
    private let settingsStore: SettingsStore
    private let graphSnapshotStore: GraphSnapshotStore
    private let mealStore: MealStore
    private let historyStore: HistoryStore
    private let makeClient: () -> LibreLinkUpClient
    private let glookoClient: GlookoClient
    private let alerter = GlucoseAlerter(allowsTimeSensitive: false)
    private var engine: PollingEngine?
    private var lastDoseFetch: Date?
    private var isSyncingGlooko = false
    private var historyRevision = 0

    init(
        credentialStore: CredentialStore = KeychainStore(),
        glookoCredentialStore: CredentialStore = KeychainStore(servicePrefix: glookoKeychainServicePrefix),
        settingsStore: SettingsStore = UserDefaultsSettingsStore(),
        graphSnapshotStore: GraphSnapshotStore = UserDefaultsGraphSnapshotStore(),
        mealStore: MealStore = UserDefaultsMealStore(),
        historyStore: HistoryStore = FileHistoryStore(),
        makeClient: @escaping () -> LibreLinkUpClient = { LibreLinkUpClient(transport: URLSessionTransport()) },
        glookoClient: GlookoClient = GlookoClient(transport: URLSessionTransport())
    ) {
        self.credentialStore = credentialStore
        self.glookoCredentialStore = glookoCredentialStore
        self.settingsStore = settingsStore
        self.graphSnapshotStore = graphSnapshotStore
        self.mealStore = mealStore
        self.historyStore = historyStore
        self.makeClient = makeClient
        self.glookoClient = glookoClient
        self.settings = settingsStore.load()
    }

    var thresholds: Thresholds { settings.thresholds }

    var content: BarContent {
        SugarbarCore.barContent(
            latest: latest,
            sensorActivation: sensorActivation,
            now: now,
            thresholds: settings.thresholds
        )
    }

    var accountEmail: String? {
        resolveCredentials()?.email
    }

    var glookoAccountEmail: String? {
        resolveGlookoCredentials()?.email
    }

    var needsDisclaimer: Bool {
        !settings.disclaimerAcknowledged
    }

    func chartSeries(window: HistoryWindow) -> [Reading] {
        _ = historyRevision
        return historyStore.readings(in: window.interval(endingAt: now))
    }

    func chartDoses(window: HistoryWindow) -> [InsulinDose] {
        _ = historyRevision
        return historyStore.doses(in: window.interval(endingAt: now))
    }

    func chartMeals(window: HistoryWindow) -> [Meal] {
        SugarbarCore.meals(meals, within: window, of: now)
    }

    func chartForecast(window: HistoryWindow) -> [ForecastPoint] {
        window.isMultiDay ? [] : forecast?.displayPoints ?? []
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
        refreshForecast()
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
        sensorActivation = nil
        forecast = nil
        availableConnections = []
        statusMessage = "Open Settings to sign in"
        graphSnapshotStore.save(GraphSnapshot(latest: nil, history: [], sensorActivation: nil))
    }

    func saveGlookoCredentials(_ credentials: Credentials) {
        try? glookoCredentialStore.saveCredentials(credentials)
        insulinSyncError = nil
        lastDoseFetch = nil
        Task { await refreshDoses() }
    }

    func signOutGlooko() {
        try? glookoCredentialStore.clearCredentials()
        insulinSyncError = nil
        lastDoseFetch = nil
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
        meals = mealStore.load()
        let outcome = await pollGlucose()
        refreshForecast()
        await alerter.evaluate(latest: latest, sensorActivation: sensorActivation, forecast: forecast, now: now)
        Task { await refreshDosesIfDue() }
        return outcome
    }

    private func pollGlucose() async -> PollOutcome {
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
            historyStore.append(readings: [snapshot.latest].compactMap(\.self) + snapshot.history)
            historyRevision += 1
            sensorActivation = snapshot.sensorActivation
            statusMessage = nil
            graphSnapshotStore.save(snapshot)
            return .success(readingAt: snapshot.latest?.timestamp ?? now)
        } catch {
            logDiagnostic("poll", error)
            statusMessage = error.sugarbarMessage
            if case LibreLinkUpError.rateLimited = error { return .rateLimited }
            return .transientFailure
        }
    }

    /// Doses only change when the pen is scanned or an entry is typed, and Glooko's CGM
    /// stream lags the sensor by hours, so Glooko is polled far less often than the sensor.
    private func refreshDosesIfDue() async {
        guard resolveGlookoCredentials() != nil else { return }
        if let lastDoseFetch, now.timeIntervalSince(lastDoseFetch) < doseRefreshInterval { return }
        await refreshDoses()
    }

    private func refreshDoses() async {
        guard let credentials = resolveGlookoCredentials(), !isSyncingGlooko else { return }
        isSyncingGlooko = true
        lastDoseFetch = Date()
        do {
            try await syncGlookoHistory(client: glookoClient, store: historyStore, credentials: credentials)
            insulinSyncError = nil
        } catch {
            logDiagnostic("glooko", error)
            insulinSyncError = error.sugarbarMessage
        }
        isSyncingGlooko = false
        historyRevision += 1
        refreshForecast()
    }

    private func refreshForecast() {
        forecast = forecastFromHistory(
            historyStore,
            meals: meals,
            sensorActivation: sensorActivation,
            settings: settings,
            now: now
        )
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

    private func resolveGlookoCredentials() -> Credentials? {
        Credentials.fromEnvironment(service: "GLOOKO") ?? (try? glookoCredentialStore.loadCredentials())
    }
}
