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

    private let settings: Settings
    private let credentialStore: CredentialStore
    private let graphSnapshotStore: GraphSnapshotStore
    private let client: LibreLinkUpClient
    private let reloadWidgets: () -> Void
    private var engine: PollingEngine?

    init(
        credentialStore: CredentialStore = KeychainStore(),
        settingsStore: SettingsStore = UserDefaultsSettingsStore(),
        graphSnapshotStore: GraphSnapshotStore = UserDefaultsGraphSnapshotStore(),
        client: LibreLinkUpClient = LibreLinkUpClient(transport: URLSessionTransport()),
        reloadWidgets: @escaping () -> Void = { WidgetCenter.shared.reloadAllTimelines() }
    ) {
        self.credentialStore = credentialStore
        self.settings = settingsStore.load()
        self.graphSnapshotStore = graphSnapshotStore
        self.client = client
        self.reloadWidgets = reloadWidgets
        self.isSignedIn = (try? credentialStore.loadCredentials()) != nil
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

    @discardableResult
    func pollOnce() async -> PollOutcome {
        now = Date()
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
}
