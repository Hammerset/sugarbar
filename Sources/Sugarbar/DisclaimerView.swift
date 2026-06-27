import SwiftUI

struct DisclaimerView: View {
    var onAcknowledge: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "drop.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.red)
                Text("Welcome to Sugarbar")
                    .font(.title2.bold())
            }

            Text("Sugarbar shows glucose readings from your LibreLinkUp follower account in the menu bar.")

            Text("It is not a medical device and is for information only. Readings can be delayed, stale, or wrong. Never make treatment decisions based on Sugarbar — always confirm with your FreeStyle Libre 3 app or a fingerstick.")
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("I Understand", action: onAcknowledge)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}
