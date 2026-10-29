import SwiftUI
import SugarbarCore

struct ClaudeAPIKeyView: View {
    let model: GlucoseViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var apiKey = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("API key (sk-ant-…)", text: $apiKey)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("A pay-per-use key from console.anthropic.com. Meal photos are sent to Claude to estimate carbohydrates; the key is stored in the Keychain on this phone only.")
                }
            }
            .navigationTitle("Claude API Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.saveClaudeAPIKey(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
