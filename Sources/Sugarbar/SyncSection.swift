import SwiftUI
import SugarbarUI

struct SyncSection: View {
    let model: BarViewModel

    var body: some View {
        Section {
            SyncSettingsRows(coordinator: model.sync, store: model.syncSettings)
        } header: {
            Text("Sync")
        } footer: {
            Text(SyncSettingsRows.footer)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
