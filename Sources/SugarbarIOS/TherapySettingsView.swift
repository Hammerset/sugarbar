import SwiftUI
import SugarbarCore
import SugarbarUI

struct TherapySettingsView: View {
    let model: GlucoseViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var therapy: TherapySettings

    init(model: GlucoseViewModel) {
        self.model = model
        _therapy = State(initialValue: model.settings.therapy)
    }

    var body: some View {
        NavigationStack {
            Form {
                if !model.therapySuggestions.isEmpty {
                    Section {
                        ForEach(model.therapySuggestions, id: \.quantity) { suggestion in
                            TherapySuggestionRow(
                                suggestion: suggestion,
                                onAccept: {
                                    model.acceptSuggestion(suggestion)
                                    therapy[suggestion.quantity] = suggestion.suggested
                                },
                                onDismiss: { model.dismissSuggestion(suggestion) }
                            )
                        }
                    }
                }
                Section {
                    TherapySettingsFields(therapy: $therapy)
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        if let error = therapy.validationError {
                            Text(error).foregroundStyle(.red)
                        }
                        Text(TherapySettingsFields.note)
                    }
                }
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
                }
                Section("Therapy Changes") {
                    TherapyChangeLogRows(changes: model.settings.therapyLearning.changes)
                }
            }
            .navigationTitle("Therapy Settings")
            .navigationBarTitleDisplayMode(.inline)
            .task { model.refreshTherapyEstimateIfDue() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.saveTherapy(therapy)
                        dismiss()
                    }
                    .disabled(!therapy.isValid)
                }
            }
        }
    }
}
