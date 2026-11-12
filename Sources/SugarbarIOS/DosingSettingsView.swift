import SwiftUI
import SugarbarCore
import SugarbarUI

struct DosingSettingsView: View {
    let store: SettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var dosing: DosingSettings

    init(store: SettingsStore = UserDefaultsSettingsStore()) {
        self.store = store
        _dosing = State(initialValue: store.load().dosing)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DosingSettingsFields(dosing: $dosing)
                } footer: {
                    Text(DosingSettingsFields.note)
                }
            }
            .navigationTitle("Dose Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var settings = store.load()
                        settings.dosing = dosing
                        store.save(settings)
                        dismiss()
                    }
                }
            }
        }
    }
}
