import SwiftUI
import SugarbarCore

struct GlookoSignInView: View {
    let model: GlucoseViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Email", text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                } footer: {
                    Text("Sugarbar reads your pen and manually logged insulin doses from your Glooko account. Doses appear once the pen has been synced to the Glooko app.")
                }
            }
            .navigationTitle("Connect Glooko")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") {
                        model.signInGlooko(Credentials(email: email, password: password))
                        dismiss()
                    }
                    .disabled(email.isEmpty || password.isEmpty)
                }
            }
        }
    }
}
