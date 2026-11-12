import SwiftUI

struct ClaudeAPIKeySection: View {
    let model: BarViewModel
    @State private var apiKey = ""

    var body: some View {
        Section {
            if model.hasClaudeAPIKey {
                LabeledContent("API key", value: "Saved in Keychain")
                Button("Remove Key", role: .destructive) {
                    model.clearClaudeAPIKey()
                }
            } else {
                SecureField("API key (sk-ant-…)", text: $apiKey)
                    .textContentType(.password)
                Button("Save Key") {
                    model.saveClaudeAPIKey(trimmedKey)
                    apiKey = ""
                }
                .disabled(trimmedKey.isEmpty)
            }
        } header: {
            Text("Claude API Key")
        } footer: {
            Text("Optional. A pay-per-use key from console.anthropic.com, stored in this Mac's Keychain. Ask Claude sends a summary of your glucose, dose and meal data to the Claude API with this key, and Log Meal sends the photo or description you ask it to estimate; nothing else leaves the Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var trimmedKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
