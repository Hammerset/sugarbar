import SwiftUI

struct PanelView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("sugarbar")
                .font(.headline)
            Text("Panel coming soon")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(20)
        .frame(width: 240, height: 160)
    }
}
