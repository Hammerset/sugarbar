import SwiftUI
import SugarbarCore

struct SettingsView: View {
    let model: BarViewModel
    let launchAtLogin: LaunchAtLoginControlling

    @State private var isSignedIn: Bool
    @State private var email: String
    @State private var password: String
    @State private var urgentLow: Double
    @State private var low: Double
    @State private var high: Double
    @State private var urgentHigh: Double
    @State private var cadence: Double
    @State private var selectedPatientId: String
    @State private var launchEnabled: Bool
    @State private var thresholdError: String?
    @State private var connectionError: String?
    @State private var didSave = false

    init(model: BarViewModel, launchAtLogin: LaunchAtLoginControlling) {
        self.model = model
        self.launchAtLogin = launchAtLogin
        let settings = model.settings
        _isSignedIn = State(initialValue: model.accountEmail != nil)
        _email = State(initialValue: model.accountEmail ?? "")
        _password = State(initialValue: "")
        _urgentLow = State(initialValue: settings.thresholds.urgentLow)
        _low = State(initialValue: settings.thresholds.low)
        _high = State(initialValue: settings.thresholds.high)
        _urgentHigh = State(initialValue: settings.thresholds.urgentHigh)
        _cadence = State(initialValue: settings.pollCadence)
        _selectedPatientId = State(initialValue: settings.selectedPatientId ?? "")
        _launchEnabled = State(initialValue: launchAtLogin.isEnabled)
    }

    var body: some View {
        Form {
            accountSection
            sensorSection
            referenceRangeSection
            pollingSection
            generalSection
            saveSection
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 640)
        .task {
            if isSignedIn, model.availableConnections.isEmpty { await loadConnections() }
        }
    }

    private var accountSection: some View {
        Section("LibreLinkUp Account") {
            if isSignedIn {
                LabeledContent("Signed in", value: email)
                Button("Sign Out", role: .destructive) {
                    model.signOut()
                    isSignedIn = false
                    password = ""
                }
            } else {
                TextField("Email", text: $email)
                    .textContentType(.username)
                SecureField("Password", text: $password)
                    .textContentType(.password)
                Button("Sign In") {
                    model.saveCredentials(Credentials(email: email, password: password))
                    isSignedIn = true
                    password = ""
                    Task { await loadConnections() }
                }
                .disabled(email.isEmpty || password.isEmpty)
            }
        }
    }

    @ViewBuilder
    private var sensorSection: some View {
        Section("Sensor") {
            if model.availableConnections.count > 1 {
                Picker("Following", selection: $selectedPatientId) {
                    Text("Automatic").tag("")
                    ForEach(model.availableConnections, id: \.patientId) { connection in
                        Text(connection.displayName).tag(connection.patientId)
                    }
                }
            } else if let only = model.availableConnections.first {
                LabeledContent("Following", value: only.displayName)
            } else {
                Text(isSignedIn ? "No connections loaded yet." : "Sign in to load sensor connections.")
                    .foregroundStyle(.secondary)
            }
            Button("Reload Connections") { Task { await loadConnections() } }
                .disabled(!isSignedIn)
            if let connectionError {
                Text(connectionError).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var referenceRangeSection: some View {
        Section("Reference Range (mmol/L)") {
            thresholdRow("Urgent low", value: $urgentLow)
            thresholdRow("Low", value: $low)
            thresholdRow("High", value: $high)
            thresholdRow("Urgent high", value: $urgentHigh)
            if let thresholdError {
                Text(thresholdError).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var pollingSection: some View {
        Section("Polling") {
            LabeledContent("Interval") {
                HStack {
                    Slider(value: $cadence, in: Settings.cadenceRange, step: 5)
                    Text("\(Int(cadence))s")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }
        }
    }

    private var generalSection: some View {
        Section {
            Toggle("Launch at login", isOn: $launchEnabled)
                .disabled(!launchAtLogin.isAvailable)
                .onChange(of: launchEnabled) { _, newValue in
                    do {
                        try launchAtLogin.setEnabled(newValue)
                    } catch {
                        launchEnabled = launchAtLogin.isEnabled
                    }
                }
            if !launchAtLogin.isAvailable {
                Text("Available when running the packaged app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var saveSection: some View {
        Section {
            HStack {
                Button("Save Changes") { saveChanges() }
                    .keyboardShortcut(.defaultAction)
                if didSave {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            Text("Not a medical device — for information only.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func thresholdRow(_ label: String, value: Binding<Double>) -> some View {
        LabeledContent(label) {
            HStack {
                TextField(label, value: value, format: .number.precision(.fractionLength(1)))
                    .labelsHidden()
                    .frame(width: 70)
                    .multilineTextAlignment(.trailing)
                Stepper(label, value: value, in: 0...40, step: 0.1)
                    .labelsHidden()
            }
        }
    }

    private func saveChanges() {
        guard let thresholds = Thresholds.validated(
            urgentLow: urgentLow, low: low, high: high, urgentHigh: urgentHigh
        ) else {
            didSave = false
            thresholdError = "Each level must be higher than the one above it."
            return
        }
        thresholdError = nil
        var updated = model.settings
        updated.thresholds = thresholds
        updated.pollCadence = cadence
        updated.selectedPatientId = selectedPatientId.isEmpty ? nil : selectedPatientId
        model.applySettings(updated)
        didSave = true
    }

    private func loadConnections() async {
        connectionError = nil
        do {
            _ = try await model.loadConnections()
        } catch {
            logDiagnostic("loadConnections", error)
            connectionError = error.sugarbarMessage
        }
    }
}

private extension Connection {
    var displayName: String {
        let name = "\(firstName) \(lastName)".trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? patientId : name
    }
}
