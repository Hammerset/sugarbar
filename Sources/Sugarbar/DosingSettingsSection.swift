import SwiftUI
import SugarbarCore
import SugarbarUI

struct DosingSettingsSection: View {
    let model: BarViewModel
    @State private var dosing: DosingSettings

    init(model: BarViewModel) {
        self.model = model
        _dosing = State(initialValue: model.settings.dosing)
    }

    var body: some View {
        Section {
            DosingSettingsFields(dosing: $dosing)
        } header: {
            Text("Dose Suggestion (Plan Meal)")
        } footer: {
            Text(DosingSettingsFields.note)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onChange(of: dosing) { _, newValue in
            var updated = model.settings
            updated.dosing = newValue
            model.applySettings(updated)
        }
    }
}
