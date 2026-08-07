import SwiftUI

/// Sign-in screen. Username is required, password is optional (Jellyfin
/// allows passwordless accounts). On success `AppState` remembers the
/// credentials so the app can sign in automatically next launch.
struct LoginView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = LoginViewModel()

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                header

                VStack(alignment: .leading, spacing: 12) {
                    TextField("Username", text: $viewModel.username)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    SecureField("Password (optional)", text: $viewModel.password)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await viewModel.signIn(using: appState) } }
                }

                if let errorMessage = viewModel.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(Color.dionysusMagenta)
                }

                Spacer()

                Button {
                    Task { await viewModel.signIn(using: appState) }
                } label: {
                    if viewModel.isSigningIn {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("Sign In").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!viewModel.canSubmit)

                Button("Use a Different Server") {
                    appState.changeServer()
                }
                .font(.footnote)
                .frame(maxWidth: .infinity)
            }
            .padding(24)
            .navigationTitle("Sign In")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            if viewModel.username.isEmpty, let username = appState.sessionStore.credentials?.username {
                viewModel.username = username
            }
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
}

#Preview {
    LoginView()
        .environment(AppState())
}
