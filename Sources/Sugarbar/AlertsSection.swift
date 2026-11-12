import SwiftUI
import SugarbarCore
import SugarbarUI

struct AlertsSection: View {
    let model: BarViewModel
    @State private var alerts: AlertSettings

    init(model: BarViewModel) {
        self.model = model
        _alerts = State(initialValue: model.settings.alerts)
    }

    var body: some View {
        Section {
            AlertSettingsRows(settings: $alerts)
        } header: {
            Text("Alerts")
        } footer: {
            Text(AlertSettingsRows.footer)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onChange(of: alerts) { _, newValue in
            var updated = model.settings
            updated.alerts = newValue
            model.applySettings(updated)
        }
    }
}
