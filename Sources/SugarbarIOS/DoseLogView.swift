import SwiftUI
import SugarbarCore
import SugarbarUI

struct DoseLogView: View {
    let model: GlucoseViewModel
    var onSaved: (InsulinDose) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss

    @State private var draft: DoseDraft

    init(model: GlucoseViewModel, initialDraft: DoseDraft = DoseDraft(), onSaved: @escaping (InsulinDose) -> Void = { _ in }) {
        self.model = model
        self.onSaved = onSaved
        _draft = State(initialValue: initialDraft)
    }

    private var warning: StackingWarning? { model.stackingWarning(for: draft) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DoseEntryFields(draft: $draft, defaultName: model.defaultInsulinName(for: draft.kind))
                }
                if let warning {
                    Section {
                        StackingWarningView(warning: warning, doseUnits: draft.units, doseTime: draft.timestamp)
                    }
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
                    Button(StackingWarningView.saveTitle(warning)) { save() }
                        .disabled(!draft.isValid)
                }
            }
        }
    }

    @ViewBuilder
    private var recentSection: some View {
        let recent = model.recentManualDoses
        if !recent.isEmpty {
            Section {
                ForEach(recent) { dose in
                    Button {
                        draft = DoseDraft(editing: dose)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(manualDoseSummary(dose))
                                .foregroundStyle(dose.id == draft.editing?.id ? dose.kind.tint : .primary)
                            GlookoStatusText(model.sync.glooko.status(of: dose), isSending: model.sync.glooko.isSending)
                        }
                    }
                }
                .onDelete { offsets in
                    for dose in offsets.map({ recent[$0] }) {
                        model.deleteManualDose(dose)
                        if dose.id == draft.editing?.id { draft = DoseDraft() }
                    }
                }
            } header: {
                Text("Entered, not yet from Glooko")
            } footer: {
                Text(DoseEntryFields.note)
            }
        }
    }

    private func save() {
        guard let dose = draft.dose(defaultName: model.defaultInsulinName(for: draft.kind)) else { return }
        model.saveManualDose(dose, replacing: draft.editing)
        if draft.editing == nil { onSaved(dose) }
        dismiss()
    }
}
