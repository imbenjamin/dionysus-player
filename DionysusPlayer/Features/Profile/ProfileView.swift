import SwiftUI

/// Account/server settings. For now: show who's signed in and where, plus
/// sign out / change server.
struct ProfileView: View {
    @Environment(AppState.self) private var appState
    @AppStorage(themePreferenceStorageKey) private var themePreference: ThemePreference = .system
    @State private var showSignOutConfirmation = false
    @State private var showChangeServerConfirmation = false

    var body: some View {
        List {
            Section("Account") {
                LabeledContent("Username", value: appState.currentUser?.name ?? appState.sessionStore.credentials?.username ?? "\u{2014}")
                LabeledContent("Server", value: appState.sessionStore.serverConfiguration?.name ?? "\u{2014}")
                LabeledContent("Address", value: appState.sessionStore.serverConfiguration?.baseURL.absoluteString ?? "\u{2014}")
            }

            Section("Appearance") {
                Picker("Theme", selection: $themePreference) {
                    ForEach(ThemePreference.allCases) { preference in
                        Text(preference.displayName).tag(preference)
                    }
                }
            }

            Section {
                Button("Sign Out", role: .destructive) {
                    showSignOutConfirmation = true
                }
            }

            Section {
                Button("Change Server", role: .destructive) {
                    showChangeServerConfirmation = true
                }
            } footer: {
                Text("This signs you out and forgets this server, returning to first-time setup.")
            }
        }
        .navigationTitle("Profile")
        .confirmationDialog(
            "Sign out of \(appState.currentUser?.name ?? "your account")?",
            isPresented: $showSignOutConfirmation,
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive) { appState.signOut() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Change server?",
            isPresented: $showChangeServerConfirmation,
            titleVisibility: .visible
        ) {
            Button("Change Server", role: .destructive) { appState.changeServer() }
            Button("Cancel", role: .cancel) {}
        }
    }
}

#Preview {
    NavigationStack { ProfileView() }
        .environment(AppState())
}
