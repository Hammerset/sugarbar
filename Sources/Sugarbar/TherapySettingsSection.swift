import SwiftUI
import SugarbarCore
import SugarbarUI

struct TherapySettingsSection: View {
    let model: BarViewModel

    @State private var therapy: TherapySettings
    @State private var error: String?
    @State private var didSave = false

    init(model: BarViewModel) {
        self.model = model
        _therapy = State(initialValue: model.settings.therapy)
    }

    var body: some View {
        Section {
            TherapySettingsFields(therapy: $therapy)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Save Therapy Settings") { save() }
                if didSave {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
        } header: {
            Text("Therapy Settings (Forecast)")
        } footer: {
            Text(TherapySettingsFields.note)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onChange(of: therapy) { didSave = false }
    }

    private func save() {
        if let message = therapy.validationError {
            error = message
            didSave = false
            return
        }
        error = nil
        var updated = model.settings
        updated.therapy = therapy
        model.applySettings(updated)
        didSave = true
    }
}
