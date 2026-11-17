import SwiftUI
import SugarbarCore
import SugarbarUI

struct DoseEntrySection: View {
    let model: BarViewModel
    @Binding var isPresented: Bool
    @State private var draft = DoseDraft()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(draft.editing == nil ? "Log Dose" : "Edit Dose")
                .font(.headline)
            Form {
                DoseEntryFields(draft: $draft, defaultName: model.defaultInsulinName(for: draft.kind))
            }
            let warning = model.stackingWarning(for: draft)
            if let warning {
                StackingWarningView(warning: warning, doseUnits: draft.units, doseTime: draft.timestamp)
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button(StackingWarningView.saveTitle(warning)) { save() }
                    .keyboardShortcut(warning == nil ? .defaultAction : nil)
                    .disabled(!draft.isValid)
            }
            recentList
        }
    }

    @ViewBuilder
    private var recentList: some View {
        let recent = model.recentManualDoses
        if !recent.isEmpty {
            Text("Entered, not yet from Glooko")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(DoseEntryFields.note)
            ForEach(recent) { dose in
                HStack {
                    Text(manualDoseSummary(dose))
                        .font(.caption)
                        .foregroundStyle(dose.id == draft.editing?.id ? dose.kind.tint : .primary)
                    Spacer()
                    Button("Edit", systemImage: "pencil") { draft = DoseDraft(editing: dose) }
                    Button("Delete", systemImage: "trash") {
                        model.deleteManualDose(dose)
                        if dose.id == draft.editing?.id { draft = DoseDraft() }
                    }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            }
        }
    }

    private func save() {
        guard let dose = draft.dose(defaultName: model.defaultInsulinName(for: draft.kind)) else { return }
        model.saveManualDose(dose, replacing: draft.editing)
        draft = DoseDraft()
        isPresented = false
    }
}
