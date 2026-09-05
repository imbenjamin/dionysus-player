import SwiftUI

/// Account details + sign-out/change-server, presented as a sheet from
/// `ProfileView`'s profile card. Moved out of the main Settings list so that
/// list reads as day-to-day preferences, with account identity and the two
/// destructive account actions living behind one tap on the card instead.
///
/// Reads `AppState` directly rather than taking parameters — same "no
/// dedicated view model" pattern `ProfileView` itself uses.
///
/// iPhone only. On iPad the same rows appear as a detail pane instead —
/// see `AccountDetailsContent`.
struct AccountDetailsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AccountDetailsContent()
                .accessibilityIdentifier(A11yID.Profile.accountSheet)
                .navigationTitle("Account")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        // `AppState.signOut()`/`changeServer()` flip `AppState.phase`, which
        // tears down `MainTabView` (and this sheet along with it) — same
        // behavior as before this sheet existed, just triggered from in here
        // instead of directly from `ProfileView`.
        .presentationDetents([.medium])
    }
}

/// The account rows themselves — identity, plus the two destructive
/// account actions — with no navigation container or dismissal affordance
/// of its own.
///
/// Split out of `AccountDetailsSheet` so iPad can show exactly the same
/// content as a detail pane rather than a sheet. On iPad the contact card
/// is a selectable sidebar row, and selecting it should fill the detail
/// column the way every other sidebar row does; throwing a medium-detent
/// sheet over a screen with a half-empty detail column already open would
/// be covering space it could simply have used.
///
/// The confirmation dialogs live here, with the buttons that raise them,
/// so both presentations get them without either having to remember to
/// attach them.
struct AccountDetailsContent: View {
    @Environment(AppState.self) private var appState
    @State private var showSignOutConfirmation = false
    @State private var showChangeServerConfirmation = false

    var body: some View {
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
                .accessibilityIdentifier(A11yID.Profile.signOutButton)
                Button("Change Server", role: .destructive) {
                    showChangeServerConfirmation = true
                }
                .accessibilityIdentifier(A11yID.Profile.changeServerButton)
            } footer: {
                Text("Change Server also signs you out and forgets this server, returning to first-time setup.")
                    .readableSettingsFooter()
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
}

#Preview {
    AccountDetailsSheet()
        .environment(AppState())
}
