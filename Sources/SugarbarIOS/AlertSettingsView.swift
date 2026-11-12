import SwiftUI
import SugarbarCore
import SugarbarUI

struct AlertSettingsView: View {
    private let settingsStore: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var alerts: AlertSettings

    init(settingsStore: SettingsStore = UserDefaultsSettingsStore()) {
        self.settingsStore = settingsStore
        _alerts = State(initialValue: settingsStore.load().alerts)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    AlertSettingsRows(settings: $alerts)
                } footer: {
                    Text(AlertSettingsRows.footer)
                }
            }
            .navigationTitle("Alerts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: alerts) { _, newValue in
                var updated = settingsStore.load()
                updated.alerts = newValue
                settingsStore.save(updated)
            }
        }
    }
}
