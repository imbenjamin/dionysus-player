import SwiftUI

/// The password route for a listed user: the fallback from Quick Connect, or
/// the only route when the server has it off. The system keyboard offers the
/// Continuity Keyboard on a nearby iPhone by itself.
struct TVPasswordSignInView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let user: UserDto
    let serverName: String
    let viewModel: LoginViewModel
    @FocusState private var fieldFocused: Bool
    @FocusState private var signInFocused: Bool

    var body: some View {
        @Bindable var viewModel = viewModel
        TVBrandBackground {
            TVOnboardingPanes {
                VStack(spacing: 28) {
                    UserAvatar(user: user, serverURL: appState.sessionStore.serverConfiguration?.baseURL, size: 260)
                    Text(verbatim: user.name).font(.title3.bold())
                    Text(verbatim: serverName).foregroundStyle(.secondary)
                }
            } task: {
                VStack(alignment: .leading, spacing: 40) {
                    Text("Enter Your Password").font(.title2.bold())
                    SecureField("Password", text: $viewModel.selectedUserPassword)
                        .frame(width: 800)
                        .focused($fieldFocused)
                        .onSubmit(signIn)
                        .accessibilityIdentifier(A11yID.TV.Onboarding.passwordField)
                    if let error = viewModel.errorMessage {
                        Text(error).foregroundStyle(.red)
                    }
                    HStack(spacing: 26) {
                        Button("Sign In", action: signIn)
                            .disabled(viewModel.isSigningIn)
                            .focused($signInFocused)
                            .accessibilityIdentifier(A11yID.TV.Onboarding.passwordSignIn)
                        Button("Cancel") { viewModel.clearSelection(); dismiss() }
                    }
                    // Down from the wide field lands on Sign In, not on
                    // Cancel, which is nearer its centre. `.userInitiated`,
                    // as the season tabs, so it applies to a press.
                    .focusSection()
                    .defaultFocus($signInFocused, true, priority: .userInitiated)
                }
            }
        }
        .task {
            // `choose` on a user with a password selects them rather than
            // signing in, so the password typed here is theirs. It toggles, so
            // it's only called when someone else (or nobody) is selected.
            if viewModel.selectedUser?.id != user.id { await viewModel.choose(user, using: appState) }
            fieldFocused = true
        }
    }

    private func signIn() {
        Task { await viewModel.signInSelectedUser(using: appState) }
    }
}
