import SwiftUI

/// Account details + sign-out/change-server, presented as a sheet from
/// `ProfileView`'s profile card. Moved out of the main Settings list so that
/// list reads as day-to-day preferences, with account identity and the two
/// destructive account actions living behind one tap on the card instead.
///
/// Reads `AppState` directly rather than taking parameters — same "no
/// dedicated view model" pattern `ProfileView` itself uses.
struct AccountDetailsSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var showSignOutConfirmation = false
    @State private var showChangeServerConfirmation = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Username", value: appState.currentUser?.name ?? appState.sessionStore.credentials?.username ?? "\u{2014}")
                    LabeledContent("Server", value: appState.sessionStore.serverConfiguration?.name ?? "\u{2014}")
                    LabeledContent("Address", value: appState.sessionStore.serverConfiguration?.baseURL.absoluteString ?? "\u{2014}")
                }

                Section {
                    Button("Sign Out", role: .destructive) {
                        showSignOutConfirmation = true
                    }
                    Button("Change Server", role: .destructive) {
                        showChangeServerConfirmation = true
                    }
                } footer: {
                    Text("Change Server also signs you out and forgets this server, returning to first-time setup.")
                }
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
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
        // `AppState.signOut()`/`changeServer()` flip `AppState.phase`, which
        // tears down `MainTabView` (and this sheet along with it) — same
        // behavior as before this sheet existed, just triggered from in here
        // instead of directly from `ProfileView`.
        .presentationDetents([.medium])
    }
}

#Preview {
    AccountDetailsSheet()
        .environment(AppState())
}
