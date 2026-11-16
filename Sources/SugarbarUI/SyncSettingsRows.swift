import SwiftUI
import SugarbarCore

public struct SyncSettingsRows: View {
    private let coordinator: SyncCoordinator
    private let store: SyncSettingsStore
    @State private var serverURL: String
    @State private var token = ""
    @State private var isEnabled: Bool
    @State private var hasToken: Bool
    @State private var saveError: String?

    public init(coordinator: SyncCoordinator, store: SyncSettingsStore) {
        self.coordinator = coordinator
        self.store = store
        _serverURL = State(initialValue: store.serverURLText)
        _isEnabled = State(initialValue: store.isEnabled)
        _hasToken = State(initialValue: store.hasToken)
    }

    public static let footer = "Your Meals, Doses, Readings and settings go to the server you configure. The access token stays in this device's Keychain; sign-ins, API keys and poll cadence are never sent."

    public var body: some View {
        Toggle("Sync with a server", isOn: $isEnabled)
            .onChange(of: isEnabled) { _, isOn in
                store.setEnabled(isOn)
                coordinator.configurationChanged()
            }
        TextField("Server URL (https://…)", text: $serverURL)
            .autocorrectionDisabled()
            #if os(iOS)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            #endif
        SecureField(hasToken ? "Access token (saved)" : "Access token", text: $token)
            .textContentType(.password)
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
        Button("Save") { save() }
            .disabled(!canSave)
        if let saveError {
            Text(saveError).font(.caption).foregroundStyle(.red)
        }
        if isEnabled, hasToken, SyncConfiguration.serverURL(from: store.serverURLText) != nil {
            HStack {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(syncStatusLine(coordinator.status, isSyncing: coordinator.isSyncing, now: context.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Sync Now") { coordinator.syncNow() }
                    .disabled(coordinator.isSyncing)
            }
            if let error = coordinator.status.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var trimmedToken: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canSave: Bool {
        SyncConfiguration.serverURL(from: serverURL) != nil && (hasToken || !trimmedToken.isEmpty)
    }

    private func save() {
        guard let url = SyncConfiguration.serverURL(from: serverURL) else { return }
        do {
            try store.save(serverURL: url, token: trimmedToken.isEmpty ? nil : trimmedToken)
            token = ""
            serverURL = url.absoluteString
            hasToken = store.hasToken
            isEnabled = true
            saveError = nil
            coordinator.configurationChanged()
        } catch {
            saveError = "Could not save the token to the Keychain."
        }
    }
}
