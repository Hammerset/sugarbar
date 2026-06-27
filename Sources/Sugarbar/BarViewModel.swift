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

    private let credentialStore: CredentialStore
    private let makeClient: () -> LibreLinkUpClient
    private var engine: PollingEngine?

    init(
        credentialStore: CredentialStore = KeychainStore(),
        makeClient: @escaping () -> LibreLinkUpClient = { LibreLinkUpClient(transport: URLSessionTransport()) }
    ) {
        self.credentialStore = credentialStore
        self.makeClient = makeClient
    }

    var displayValue: String {
        guard let latest else { return "—" }
        return formatMmolPerL(latest.value)
    }

    var band: Band? {
        latest.map { Band(mmolPerL: $0.value) }
    }

    var isStale: Bool {
        latest?.isStale(at: now) ?? false
    }

    var trendSymbolName: String? {
        isStale ? nil : latest?.trend.symbolName
    }

    func chartSeries(window: HistoryWindow) -> [Reading] {
        guard let latest else {
            return readings(history, within: window, of: now)
        }
        return readings(mergeReadings(history: history, latest: latest), within: window, of: now)
    }

    func start() {
        guard engine == nil else { return }
        let engine = PollingEngine { [weak self] in
            await self?.pollOnce() ?? .transientFailure
        }
        self.engine = engine
        Task { await engine.start() }
    }

    func pause() {
        guard let engine else { return }
        Task { await engine.stop() }
    }

    func resume() {
        guard let engine else { return }
        Task { await engine.start() }
    }

    @discardableResult
    func pollOnce() async -> PollOutcome {
        now = Date()
        guard let credentials = resolveCredentials() else {
            statusMessage = "Set SUGARBAR_LIBRE_EMAIL and SUGARBAR_LIBRE_PASSWORD"
            return .transientFailure
        }
        do {
            let snapshot = try await makeClient().fetchGraph(
                email: credentials.email,
                password: credentials.password
            )
            latest = snapshot.latest
            history = snapshot.history
            statusMessage = nil
            return .success(readingAt: snapshot.latest.timestamp)
        } catch LibreLinkUpError.rateLimited {
            statusMessage = "Rate limited — backing off"
            return .rateLimited
        } catch {
            statusMessage = String(describing: error)
            return .transientFailure
        }
    }

    private func resolveCredentials() -> Credentials? {
        Credentials.fromEnvironment() ?? (try? credentialStore.loadCredentials())
    }
}
