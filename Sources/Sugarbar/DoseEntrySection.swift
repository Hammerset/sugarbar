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
            Text(DoseEntryFields.note)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
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
