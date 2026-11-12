import SwiftUI
import SugarbarCore
import SugarbarUI

struct TherapySettingsView: View {
    let store: SettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var therapy: TherapySettings

    init(store: SettingsStore = UserDefaultsSettingsStore()) {
        self.store = store
        _therapy = State(initialValue: store.load().therapy)
    }

    var body: some View {
        NavigationStack {
            Form {
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
            }
            .navigationTitle("Therapy Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var settings = store.load()
                        settings.therapy = therapy
                        store.save(settings)
                        dismiss()
                    }
                    .disabled(!therapy.isValid)
                }
            }
        }
    }
}
