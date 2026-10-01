import SwiftUI

/// Profile: who is signed in, to which server, and the two ways out. Switch
/// User signs this Apple TV user out of Jellyfin, back to Who's Watching.
/// Change Server forgets the household's server for every Apple TV user, so
/// it asks first. Below them, Follow Apple TV Users chooses between a session
/// per Apple TV user and one everyone shares (`SessionScopeSetting`).
/// Milestone 3 adds the iOS settings sections above these.
struct TVProfileView: View {
    @Environment(AppState.self) private var appState
    @State private var confirmsChangeServer = false
    /// Switch User is the default focus (`tvClaimsFocus`).
    private enum Action: Hashable { case switchUser, changeServer, followsAppleTVUsers }
    @FocusState private var focusedAction: Action?
    @State private var rememberedAction: Action?
    /// A copy to draw from: the setting lives in the keychain, which nothing
    /// observes.
    @State private var followsAppleTVUsers = SessionScopeSetting.followsAppleTVUsers

    private var user: UserDto? {
        TVProfileIdentity.user(currentUser: appState.currentUser, credentials: appState.sessionStore.credentials)
    }

    var body: some View {
        TVPageScaffold {
            details
        }
        .tvClaimsFocus($focusedAction, ids: [.switchUser, .changeServer, .followsAppleTVUsers], remembered: $rememberedAction)
        // A cover of our own rather than `.confirmationDialog`, whose buttons
        // lose their accessibility identifiers on tvOS.
        .fullScreenCover(isPresented: $confirmsChangeServer) {
            TVChangeServerConfirmation { appState.changeServer() }
        }
    }

    private var details: some View {
        VStack(spacing: 40) {
            if let user {
                UserAvatar(user: user, serverURL: appState.sessionStore.serverConfiguration?.baseURL, size: 220)
                Text(verbatim: user.name)
                    .font(.title2.bold())
                    .accessibilityIdentifier(A11yID.TV.Profile.name)
            }
            if let server = appState.sessionStore.serverConfiguration {
                Text(verbatim: server.name)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(A11yID.TV.Profile.server)
            }
            VStack(spacing: 24) {
                // Widths on the labels: a tvOS button sizes its capsule to
                // its label and centres it in any outer frame.
                Button { appState.signOut() } label: {
                    Text("Switch User").frame(width: 500)
                }
                .focused($focusedAction, equals: .switchUser)
                .accessibilityIdentifier(A11yID.TV.Profile.switchUser)
                Button { confirmsChangeServer = true } label: {
                    Text("Change Server").frame(width: 500)
                }
                .focused($focusedAction, equals: .changeServer)
                .accessibilityIdentifier(A11yID.TV.Profile.changeServer)
            }
            VStack(spacing: 20) {
                Toggle("Follow Apple TV Users", isOn: Binding(
                    get: { followsAppleTVUsers },
                    set: { follows in
                        followsAppleTVUsers = follows
                        appState.setFollowsAppleTVUsers(follows)
                    }
                ))
                .frame(width: 560)
                .focused($focusedAction, equals: .followsAppleTVUsers)
                .accessibilityIdentifier(A11yID.TV.Profile.followsAppleTVUsers)
                Text("Attempts to match Jellyfin users to this Apple TV's users. Turn off to keep user switching inside the app, and when users become out of sync.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 900)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.trailing, TVShellMetrics.contentInset)
    }
}

/// Asks before Change Server, which forgets the server for every Apple TV
/// user: their stored sign-ins then fail the server check at launch, so they
/// all start again. Cancel takes focus, so a stray Select changes nothing.
private struct TVChangeServerConfirmation: View {
    @Environment(\.dismiss) private var dismiss
    let onConfirm: () -> Void
    @FocusState private var cancelFocused: Bool

    var body: some View {
        VStack(spacing: 40) {
            Text("Change Server?").font(.title2.bold())
            Text("Everyone on this Apple TV will need to find a server and sign in again.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 900)
            VStack(spacing: 24) {
                Button(role: .destructive) {
                    dismiss()
                    onConfirm()
                } label: {
                    Text("Change Server").frame(width: 500)
                }
                .accessibilityIdentifier(A11yID.TV.Profile.changeServerConfirm)
                Button(role: .cancel) { dismiss() } label: {
                    Text("Cancel").frame(width: 500)
                }
                .focused($cancelFocused)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Opaque enough that Profile's own text and buttons don't read
        // through as part of the question.
        .background { Rectangle().fill(.ultraThickMaterial).ignoresSafeArea() }
        .defaultFocus($cancelFocused, true)
    }
}
