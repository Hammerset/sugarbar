import SwiftUI
import SugarbarUI

struct SyncSettingsView: View {
    let model: GlucoseViewModel

    var body: some View {
        Form {
            Section {
                SyncSettingsRows(coordinator: model.sync, store: model.syncSettings)
            } footer: {
                Text(SyncSettingsRows.footer)
            }
        }
        .navigationTitle("Sync")
        .navigationBarTitleDisplayMode(.inline)
    }
}
