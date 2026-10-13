import Foundation
import Observation
import SugarbarCore
import WidgetKit

@MainActor
@Observable
final class GlucoseViewModel {
    private(set) var latest: Reading?
    private(set) var history: [Reading] = []
    private(set) var sensorActivation: Date?
    private(set) var statusMessage: String?
    private(set) var now = Date()
    private(set) var isSignedIn: Bool
    private(set) var isGlookoSignedIn: Bool
    private(set) var doses: [InsulinDose] = []
    private(set) var insulinSyncError: String?

    private let settings: Settings
    private let credentialStore: CredentialStore
    private let glookoCredentialStore: CredentialStore
    private let graphSnapshotStore: GraphSnapshotStore
    private let client: LibreLinkUpClient
    private let glookoClient: GlookoClient
    private let reloadWidgets: () -> Void
    private var engine: PollingEngine?
    private var lastDoseFetch: Date?

    init(
        credentialStore: CredentialStore = KeychainStore(),
        glookoCredentialStore: CredentialStore = KeychainStore(servicePrefix: glookoKeychainServicePrefix),
        settingsStore: SettingsStore = UserDefaultsSettingsStore(),
        graphSnapshotStore: GraphSnapshotStore = UserDefaultsGraphSnapshotStore(),
        client: LibreLinkUpClient = LibreLinkUpClient(transport: URLSessionTransport()),
        glookoClient: GlookoClient = GlookoClient(transport: URLSessionTransport()),
        reloadWidgets: @escaping () -> Void = { WidgetCenter.shared.reloadAllTimelines() }
    ) {
        self.credentialStore = credentialStore
        self.glookoCredentialStore = glookoCredentialStore
        self.settings = settingsStore.load()
        self.graphSnapshotStore = graphSnapshotStore
        self.client = client
        self.glookoClient = glookoClient
        self.reloadWidgets = reloadWidgets
        self.isSignedIn = (try? credentialStore.loadCredentials()) != nil
        self.isGlookoSignedIn = (try? glookoCredentialStore.loadCredentials()) != nil
    }

    var thresholds: Thresholds { settings.thresholds }

    var content: BarContent {
        barContent(latest: latest, sensorActivation: sensorActivation, now: now, thresholds: settings.thresholds)
    }

    func chartSeries(window: HistoryWindow) -> [Reading] {
        guard let latest else {
            return readings(history, within: window, of: now)
        }
        return readings(mergeReadings(history: history, latest: latest), within: window, of: now)
    }

    func chartDoses(window: HistoryWindow) -> [InsulinDose] {
        insulinDoses(doses, within: window, of: now)
    }

    func start() {
        guard engine == nil else { return }
        let engine = PollingEngine(planner: PollPlanner(cadence: settings.pollCadence)) { [weak self] in
            await self?.pollOnce() ?? .transientFailure
        }
        self.engine = engine
        Task { await engine.start() }
    }

    func stop() {
        guard let engine else { return }
        self.engine = nil
        Task { await engine.stop() }
    }

    func signIn(_ credentials: Credentials) {
        try? credentialStore.saveCredentials(credentials)
        try? credentialStore.clearToken()
        statusMessage = nil
        isSignedIn = true
        start()
    }

    func signOut() {
        stop()
        try? credentialStore.clearCredentials()
        try? credentialStore.clearToken()
        latest = nil
        history = []
        sensorActivation = nil
        statusMessage = nil
        isSignedIn = false
        graphSnapshotStore.save(GraphSnapshot(latest: nil, history: [], sensorActivation: nil))
        reloadWidgets()
    }

    func signInGlooko(_ credentials: Credentials) {
        try? glookoCredentialStore.saveCredentials(credentials)
        isGlookoSignedIn = true
        insulinSyncError = nil
        lastDoseFetch = nil
        Task { await refreshDoses() }
    }

    func signOutGlooko() {
        try? glookoCredentialStore.clearCredentials()
        isGlookoSignedIn = false
        doses = []
        insulinSyncError = nil
        lastDoseFetch = nil
    }

    /// Background refreshes skip Glooko: nothing in the widget shows doses, and the task budget is tight.
    @discardableResult
    func pollOnce(includingInsulin: Bool = true) async -> PollOutcome {
        now = Date()
        let outcome = await pollGlucose()
        if includingInsulin { await refreshDosesIfDue() }
        return outcome
    }

    private func pollGlucose() async -> PollOutcome {
        guard let credentials = try? credentialStore.loadCredentials() else {
            statusMessage = "Sign in to see your glucose"
            return .transientFailure
        }
        do {
            let snapshot = try await client.fetchGraph(
                email: credentials.email,
                password: credentials.password,
                preferredPatientId: settings.selectedPatientId
            )
            latest = snapshot.latest
            history = snapshot.history
            sensorActivation = snapshot.sensorActivation
            statusMessage = nil
            graphSnapshotStore.save(snapshot)
            reloadWidgets()
            return .success(readingAt: snapshot.latest?.timestamp ?? now)
        } catch {
            logDiagnostic("poll", error)
            statusMessage = error.sugarbarMessage
            if case LibreLinkUpError.rateLimited = error { return .rateLimited }
            return .transientFailure
        }
    }

    private func refreshDosesIfDue() async {
        guard isGlookoSignedIn else { return }
        if let lastDoseFetch, now.timeIntervalSince(lastDoseFetch) < doseRefreshInterval { return }
        await refreshDoses()
    }

    private func refreshDoses() async {
        guard let credentials = try? glookoCredentialStore.loadCredentials() else { return }
        let fetchedAt = Date()
        do {
            doses = try await glookoClient.fetchDoses(
                email: credentials.email,
                password: credentials.password,
                from: fetchedAt.addingTimeInterval(-doseLookback),
                to: fetchedAt.addingTimeInterval(60)
            )
            insulinSyncError = nil
        } catch {
            logDiagnostic("glooko", error)
            insulinSyncError = error.sugarbarMessage
        }
        lastDoseFetch = fetchedAt
    }
}
