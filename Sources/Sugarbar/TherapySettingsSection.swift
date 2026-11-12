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
            ForEach(model.therapySuggestions, id: \.quantity) { suggestion in
                TherapySuggestionRow(
                    suggestion: suggestion,
                    onAccept: { model.acceptSuggestion(suggestion) },
                    onDismiss: { model.dismissSuggestion(suggestion) }
                )
            }
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
        .onChange(of: model.settings.therapy) { _, saved in therapy = saved }

        Section {
            TherapyEstimateRows(
                estimate: model.therapyEstimate,
                therapy: model.settings.therapy,
                isEstimating: model.isEstimatingTherapy,
                onEstimate: model.recomputeTherapyEstimate
            )
        } header: {
            Text("Learned from History")
        } footer: {
            Text(TherapyEstimateRows.note)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task { model.refreshTherapyEstimateIfDue() }

        Section("Therapy Changes") {
            TherapyChangeLogRows(changes: model.settings.therapyLearning.changes)
        }
    }

    private func save() {
        if let message = therapy.validationError {
            error = message
            didSave = false
            return
        }
        error = nil
        model.saveTherapy(therapy)
        didSave = true
    }
}
