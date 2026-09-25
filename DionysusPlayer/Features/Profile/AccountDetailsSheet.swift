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
    /// Medium for the account rows; large while Quick Connect is pushed, whose
    /// code field and keyboard don't fit in half a screen.
    @State private var detent: PresentationDetent = .medium

    var body: some View {
        NavigationStack {
            AccountDetailsContent(onQuickConnectPresentedChange: { isPresented in
                detent = isPresented ? .large : .medium
            })
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
        // Not `[.medium]` alone: `AddToPlaylistSheet` records that a push
        // inside a fixed `.medium` detent loses its taps to the sheet's
        // resize gesture, and Quick Connect pushes from here.
        .presentationDetents([.medium, .large], selection: $detent)
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
    @State private var isQuickConnectAvailable = false
    @State private var isShowingQuickConnect = false

    /// Lets `AccountDetailsSheet` size itself for the pushed Quick Connect
    /// screen. The iPad detail pane has the room already and ignores it.
    var onQuickConnectPresentedChange: (Bool) -> Void = { _ in }

    var body: some View {
        List {
            Section {
                LabeledContent("Username", value: appState.currentUser?.name ?? appState.sessionStore.credentials?.username ?? "\u{2014}")
                LabeledContent("Server", value: appState.sessionStore.serverConfiguration?.name ?? "\u{2014}")
                LabeledContent("Address", value: appState.sessionStore.serverConfiguration?.baseURL.absoluteString ?? "\u{2014}")
            }

            if isQuickConnectAvailable {
                Section {
                    // A `Button` driving `.navigationDestination`, not a
                    // `NavigationLink` row — the same choice, and reason, as
                    // `AddToPlaylistSheet`'s rows.
                    Button {
                        isShowingQuickConnect = true
                    } label: {
                        HStack {
                            // `Color.primary`, not `.primary`: the hierarchical
                            // style resolves against a List button's tint, which
                            // drew this navigation row in the accent colour of
                            // an action.
                            Text("Quick Connect")
                                .foregroundStyle(Color.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        // A label with a `Spacer` only hit-tests where it paints.
                        .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier(A11yID.Profile.quickConnectRow)
                } footer: {
                    Text("Sign in on another device with a code, instead of typing your password.")
                        .readableSettingsFooter()
                }
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
            // The server, not the user: you sign out *of* a server, and the
            // username is already on the sheet behind this dialog.
            "Sign out of \(appState.sessionStore.serverConfiguration?.name ?? String(localized: "your server"))?",
            isPresented: $showSignOutConfirmation,
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive) { appState.signOut() }
            Button("Cancel", role: .cancel) {}
        }
        .task {
            guard let client = appState.apiClient else { return }
            isQuickConnectAvailable = await QuickConnectApprovalViewModel.isAvailable(on: client)
        }
        .navigationDestination(isPresented: $isShowingQuickConnect) {
            if let client = appState.apiClient {
                QuickConnectApprovalView(
                    client: client,
                    userName: appState.currentUser?.name ?? appState.sessionStore.credentials?.username ?? "",
                    serverName: appState.sessionStore.serverConfiguration?.name ?? String(localized: "your server")
                )
            }
        }
        .onChange(of: isShowingQuickConnect) { _, isPresented in
            onQuickConnectPresentedChange(isPresented)
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
