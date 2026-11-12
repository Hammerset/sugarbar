import SwiftUI
import SugarbarUI

struct AskClaudeSheet: View {
    let model: GlucoseViewModel
    let askModel: AskClaudeModel
    @Environment(\.dismiss) private var dismiss
    @State private var showClaudeKey = false

    var body: some View {
        NavigationStack {
            AskClaudeView(model: askModel) { showClaudeKey = true }
                .navigationTitle("Ask Claude")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Start Over", systemImage: "arrow.counterclockwise") { askModel.startOver() }
                            .disabled(askModel.messages.isEmpty || askModel.isSending)
                    }
                }
                .sheet(isPresented: $showClaudeKey) {
                    ClaudeAPIKeyView(model: model)
                }
        }
    }
}
