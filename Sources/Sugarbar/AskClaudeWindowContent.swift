import SwiftUI
import SugarbarUI

struct AskClaudeWindowContent: View {
    let model: AskClaudeModel
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if !model.messages.isEmpty {
                HStack {
                    Spacer()
                    Button("Start Over", systemImage: "arrow.counterclockwise") { model.startOver() }
                        .disabled(model.isSending)
                }
                .padding([.horizontal, .top])
            }
            AskClaudeView(model: model, onAddKey: onOpenSettings)
        }
        .frame(minWidth: 420, idealWidth: 480, minHeight: 480, idealHeight: 620)
    }
}
