import SwiftUI
import SugarbarCore
import SugarbarUI

struct SettingsScreen: View {
    let model: GlucoseViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Glucose & Alerts") {
                    NavigationLink {
                        AlertSettingsView()
                    } label: {
                        Label("Alerts", systemImage: "bell")
                    }
                }
                Section("Insulin & Meals") {
                    NavigationLink {
                        TherapySettingsView(model: model)
                    } label: {
                        Label("Therapy Settings", systemImage: "slider.horizontal.3")
                    }
                    NavigationLink {
                        DosingSettingsView()
                    } label: {
                        Label("Dose Settings", systemImage: "syringe")
                    }
                }
                Section {
                    glookoRow
                    NavigationLink {
                        SyncSettingsView(model: model)
                    } label: {
                        Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                    }
                    Button("Sign Out of LibreLinkUp", role: .destructive) {
                        dismiss()
                        model.signOut()
                    }
                } header: {
                    Text("Accounts & Sync")
                }
                healthSection
                Section {
                    claudeRow
                } header: {
                    Text("Claude")
                } footer: {
                    if !model.hasClaudeAPIKey {
                        Text("Add a key to estimate carbs from a photo or description and to ask Claude about your data. You confirm every Estimate before the meal is saved to Apple Health.")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var glookoRow: some View {
        if model.isGlookoSignedIn {
            LabeledContent {
                Text("Connected")
            } label: {
                Label("Glooko", systemImage: "drop")
            }
            if let error = model.insulinSyncError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            Button("Disconnect Glooko", role: .destructive) { model.signOutGlooko() }
        } else {
            NavigationLink {
                GlookoSignInView(model: model)
            } label: {
                LabeledContent {
                    Text("Not connected")
                } label: {
                    Label("Glooko", systemImage: "drop")
                }
            }
        }
    }

    @ViewBuilder
    private var healthSection: some View {
        if model.healthAccess != .unavailable {
            Section {
                LabeledContent {
                    Text(healthStatus)
                } label: {
                    Label("Save Meals", systemImage: "heart")
                }
                if model.healthAccess == .notDetermined {
                    Button("Allow Saving to Apple Health") { Task { await model.authorizeHealth() } }
                }
            } header: {
                Text("Apple Health")
            } footer: {
                if model.healthAccess == .denied {
                    Text("Meals stay in Sugarbar but are not saved to Apple Health. Turn on Carbohydrates in the Health app under Sharing › Apps › Sugarbar.")
                }
            }
        }
    }

    private var healthStatus: String {
        switch model.healthAccess {
        case .allowed: "On"
        case .denied: "Off"
        case .notDetermined, .unavailable: "Not set up"
        }
    }

    @ViewBuilder
    private var claudeRow: some View {
        if model.hasClaudeAPIKey {
            LabeledContent {
                Text("Saved")
            } label: {
                Label("API Key", systemImage: "key")
            }
            Button("Remove Claude API Key", role: .destructive) { model.clearClaudeAPIKey() }
        } else {
            NavigationLink {
                ClaudeAPIKeyView(model: model)
            } label: {
                Label("Add API Key", systemImage: "key")
            }
        }
    }
}
