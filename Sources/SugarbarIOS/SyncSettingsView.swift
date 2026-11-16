import SwiftUI
import SugarbarUI

struct SyncSettingsView: View {
    let model: GlucoseViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SyncSettingsRows(coordinator: model.sync, store: model.syncSettings)
                } footer: {
                    Text(SyncSettingsRows.footer)
                }
            }
            .navigationTitle("Sync")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
