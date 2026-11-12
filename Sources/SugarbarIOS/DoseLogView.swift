import SwiftUI
import SugarbarCore
import SugarbarUI

struct DoseLogView: View {
    let model: GlucoseViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var draft = DoseDraft()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DoseEntryFields(draft: $draft, defaultName: model.defaultInsulinName(for: draft.kind))
                } footer: {
                    Text(DoseEntryFields.note)
                }
                recentSection
            }
            .navigationTitle(draft.editing == nil ? "Log Dose" : "Edit Dose")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!draft.isValid)
                }
            }
        }
    }

    @ViewBuilder
    private var recentSection: some View {
        let recent = model.recentManualDoses
        if !recent.isEmpty {
            Section("Entered, not yet from Glooko") {
                ForEach(recent) { dose in
                    Button {
                        draft = DoseDraft(editing: dose)
                    } label: {
                        Text(manualDoseSummary(dose))
                            .foregroundStyle(dose.id == draft.editing?.id ? dose.kind.tint : .primary)
                    }
                }
                .onDelete { offsets in
                    for dose in offsets.map({ recent[$0] }) {
                        model.deleteManualDose(dose)
                        if dose.id == draft.editing?.id { draft = DoseDraft() }
                    }
                }
            }
        }
    }

    private func save() {
        guard let dose = draft.dose(defaultName: model.defaultInsulinName(for: draft.kind)) else { return }
        model.saveManualDose(dose, replacing: draft.editing)
        dismiss()
    }
}
