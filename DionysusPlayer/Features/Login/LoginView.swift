import SwiftUI

/// Sign-in screen. Username is required, password is optional (Jellyfin
/// allows passwordless accounts). On success `AppState` remembers the
/// credentials so the app can sign in automatically next launch.
///
/// Has no `NavigationStack`, for the reasons given on `ServerSetupView`.
struct LoginView: View {
    /// The two credential fields, so Return can move from one to the
    /// other instead of dead-ending on the first.
    private enum Field {
        case username
        case password
    }

    @Environment(AppState.self) private var appState
    @State private var viewModel = LoginViewModel()
    @FocusState private var focusedField: Field?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                VStack(alignment: .leading, spacing: 12) {
                    TextField("Username", text: $viewModel.username)
                        .textFieldStyle(.roundedBorder)
                        // Without an explicit content type the Passwords
                        // app has only iOS's placeholder heuristics to go
                        // on, which is what decides whether it offers to
                        // save the pair after a successful sign-in.
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focusedField, equals: .username)
                        // These fields have no visible label of their
                        // own — the placeholder was doing that job, and
                        // it disappears on the first keystroke, leaving
                        // VoiceOver announcing the typed text with
                        // nothing to say what it is.
                        .accessibilityLabel("Username")
                        .onSubmit { focusedField = .password }

                    SecureField("Password (optional)", text: $viewModel.password)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.password)
                        .submitLabel(.go)
                        .focused($focusedField, equals: .password)
                        .accessibilityLabel("Password (optional)")
                        .onSubmit { Task { await viewModel.signIn(using: appState) } }
                }

                if let errorMessage = viewModel.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        // See `ServerSetupView` for what this colour
                        // change does and doesn't change.
                        .foregroundStyle(Color.dionysusPrimary)
                }
            }
            .padding(SignInLayout.contentPadding)
            .signInColumn()
        }
        .safeAreaInset(edge: .bottom) { actions }
        .onAppear {
            if viewModel.username.isEmpty, let username = appState.sessionStore.credentials?.username {
                viewModel.username = username
            }
            // Matches `ServerSetupView`, which has always taken focus on
            // appear. Skips ahead to the password when the username came
            // back from the keychain, since that field is already done.
            focusedField = viewModel.username.isEmpty ? .username : .password
        }
        .onChange(of: viewModel.errorMessage) { _, message in
            guard let message else { return }
            AccessibilityNotification.Announcement(message).post()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(appState.sessionStore.serverConfiguration?.name ?? String(localized: "Your Server"))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("Welcome Back")
                .font(.largeTitle.bold())
        }
    }

    private var actions: some View {
        VStack(spacing: 4) {
            Button {
                Task { await viewModel.signIn(using: appState) }
            } label: {
                Group {
                    if viewModel.isSigningIn {
                        ProgressView()
                    } else {
                        Text("Sign In")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!viewModel.canSubmit)
            .accessibilityLabel("Sign In")
            .accessibilityValue(viewModel.isSigningIn ? String(localized: "Signing In") : "")

            // Stays visually tertiary — footnote text, no button styling
            // — but gets a real target. As a bare `Button` its tappable
            // area was its own text bounds, measured 125.5 x 14.5pt
            // against HIG's 44x44 default and 28x28 floor. The frame
            // alone isn't enough, and it has to go on the *label*: a
            // button hit-tests where its label paints, so a frame
            // applied outside the `Button` grows the layout — and the
            // accessibility frame that gets measured — while leaving the
            // real target the size of the text.
            Button {
                appState.changeServer()
            } label: {
                Text("Use a Different Server")
                    .font(.footnote)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, SignInLayout.contentPadding)
        .padding(.vertical, 12)
        .signInColumn()
        .background(.bar)
    }
}

#Preview {
    LoginView()
        .environment(AppState())
}
