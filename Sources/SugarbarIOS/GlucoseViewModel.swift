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
    private(set) var meals: [Meal] = []
    private(set) var hasClaudeAPIKey: Bool
    private(set) var healthKitError: String?

    private let settings: Settings
    private let credentialStore: CredentialStore
    private let glookoCredentialStore: CredentialStore
    private let graphSnapshotStore: GraphSnapshotStore
    private let client: LibreLinkUpClient
    private let glookoClient: GlookoClient
    private let mealStore: MealStore
    private let claudeKeyStore: CredentialStore
    private let mealAnalyzer: MealAnalyzer
    private let carbWriter: HealthKitCarbWriter
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
        mealStore: MealStore = UserDefaultsMealStore(),
        claudeKeyStore: CredentialStore = KeychainStore(servicePrefix: anthropicKeychainServicePrefix),
        mealAnalyzer: MealAnalyzer = MealAnalyzer(transport: URLSessionTransport()),
        carbWriter: HealthKitCarbWriter = HealthKitCarbWriter(),
        reloadWidgets: @escaping () -> Void = { WidgetCenter.shared.reloadAllTimelines() }
    ) {
        self.credentialStore = credentialStore
        self.glookoCredentialStore = glookoCredentialStore
        self.settings = settingsStore.load()
        self.graphSnapshotStore = graphSnapshotStore
        self.client = client
        self.glookoClient = glookoClient
        self.mealStore = mealStore
        self.claudeKeyStore = claudeKeyStore
        self.mealAnalyzer = mealAnalyzer
        self.carbWriter = carbWriter
        self.reloadWidgets = reloadWidgets
        self.isSignedIn = (try? credentialStore.loadCredentials()) != nil
        self.isGlookoSignedIn = (try? glookoCredentialStore.loadCredentials()) != nil
        self.meals = mealStore.load()
        self.hasClaudeAPIKey = Self.resolveClaudeAPIKey(claudeKeyStore) != nil
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

    func chartMeals(window: HistoryWindow) -> [Meal] {
        SugarbarCore.meals(meals, within: window, of: now)
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

    func saveClaudeAPIKey(_ key: String) {
        try? claudeKeyStore.saveToken(key)
        hasClaudeAPIKey = true
    }

    func clearClaudeAPIKey() {
        try? claudeKeyStore.clearToken()
        hasClaudeAPIKey = Self.resolveClaudeAPIKey(claudeKeyStore) != nil
    }

    func estimateMeal(imageJPEG: Data, note: String) async throws -> MealEstimate {
        guard let apiKey = Self.resolveClaudeAPIKey(claudeKeyStore) else { throw MealAnalyzerError.invalidAPIKey }
        return try await mealAnalyzer.estimate(imageJPEG: imageJPEG, note: note, apiKey: apiKey)
    }

    func logMeal(_ meal: Meal) async {
        meals = (meals + [meal]).sorted { $0.timestamp < $1.timestamp }
        mealStore.save(meals)
        do {
            try await carbWriter.write(meal)
            healthKitError = nil
        } catch {
            logDiagnostic("healthkit", error)
            healthKitError = "Saved here, but not to Apple Health: \(error.sugarbarMessage)"
        }
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

    private static func resolveClaudeAPIKey(_ store: CredentialStore) -> String? {
        anthropicAPIKey() ?? (try? store.loadToken())
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
