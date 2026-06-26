import Foundation
import Observation
import SugarbarCore

@MainActor
@Observable
final class BarViewModel {
    private(set) var latest: Reading?
    private(set) var statusMessage: String?

    private let credentialStore: CredentialStore
    private let makeClient: () -> LibreLinkUpClient

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

    var trendSymbolName: String? {
        latest?.trend.symbolName
    }

    func refresh() async {
        guard let credentials = resolveCredentials() else {
            statusMessage = "Set SUGARBAR_LIBRE_EMAIL and SUGARBAR_LIBRE_PASSWORD"
            return
        }
        do {
            latest = try await makeClient().fetchLatestReading(
                email: credentials.email,
                password: credentials.password
            )
            statusMessage = nil
        } catch {
            statusMessage = String(describing: error)
        }
    }

    private func resolveCredentials() -> Credentials? {
        Credentials.fromEnvironment() ?? (try? credentialStore.loadCredentials())
    }
}
