import SwiftUI
import SugarbarCore

struct SignInView: View {
    let model: GlucoseViewModel

    @State private var email = ""
    @State private var password = ""

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            VStack(spacing: 8) {
                Image(systemName: "drop.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.red)
                Text("Sign in to LibreLinkUp")
                    .font(.title2.bold())
                Text("Sugarbar reads your glucose from your LibreLinkUp follower account.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                TextField("Email", text: $email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .textFieldStyle(.roundedBorder)
            }

            if let statusMessage = model.statusMessage {
                Text(statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Button("Sign In") {
                model.signIn(Credentials(email: email, password: password))
                password = ""
            }
            .buttonStyle(.borderedProminent)
            .disabled(email.isEmpty || password.isEmpty)

            Spacer()

            Text("Not a medical device — for information only.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(24)
    }
}
