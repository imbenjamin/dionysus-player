import SwiftUI

/// Who's Watching?, on the shared `LoginViewModel`: the server's public users as
/// focusable cards. A user without a password signs in on Select; anyone else
/// gets a password field. With no public users, a plain username and password
/// form. Quick Connect is offered whenever the server has it on.
/// Functional only: the prototype's visual design lands in Milestone 2.
struct TVLoginView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = LoginViewModel()
    @State private var showsQuickConnect = false
    @FocusState private var focusedUserID: String?
    /// As on Find Your Server: the users arrive after the first focus pass, so
    /// the first one takes focus when they load, unless the person has moved.
    @State private var userMovedFocus = false

    private var serverName: String {
        appState.sessionStore.serverConfiguration?.name ?? String(localized: "Your Server")
    }

    var body: some View {
        TVBrandBackground {
            VStack(spacing: 50) {
                Text("Who's Watching?")
                    .font(.title2.bold())
                    .accessibilityIdentifier(A11yID.TV.Onboarding.whosWatchingTitle)
                users
                if viewModel.selectedUser != nil {
                    selectedUserPasswordRow
                }
                if viewModel.isQuickConnectAvailable {
                    Button("Sign In with Quick Connect") { showsQuickConnect = true }
                }
                if let error = viewModel.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
                Button("Change Server") { appState.changeServer() }
            }
            .padding(80)
        }
        .task { await viewModel.load(using: appState) }
        .onChange(of: firstUserID) { _, firstID in
            guard !userMovedFocus, focusedUserID == nil, let firstID else { return }
            focusedUserID = firstID
        }
        .onMoveCommand { _ in userMovedFocus = true }
        .fullScreenCover(isPresented: $showsQuickConnect) {
            if let client = appState.apiClient {
                TVQuickConnectView(client: client, serverName: serverName)
            }
        }
    }

    private var firstUserID: String? {
        if case .loaded(let users) = viewModel.usersState { users.first?.id } else { nil }
    }

    @ViewBuilder
    private var users: some View {
        switch viewModel.usersState {
        case .loading:
            ProgressView()
        case .loaded(let users) where !users.isEmpty:
            HStack(spacing: 60) {
                ForEach(users) { user in
                    Button {
                        Task { await viewModel.choose(user, using: appState) }
                    } label: {
                        VStack(spacing: 20) {
                            // The profile picture, over the monogram it falls
                            // back to — the same avatar as iOS's sign-in.
                            UserAvatar(user: user, serverURL: appState.sessionStore.serverConfiguration?.baseURL, size: 200)
                            Text(user.name)
                        }
                        .padding(30)
                    }
                    // The system card, for its native lift, parallax and sheen.
                    // `.borderless` shows no focus on a label with no image of
                    // its own, and a hand-rolled circular lift loses the sheen.
                    .buttonStyle(.card)
                    .focused($focusedUserID, equals: user.id)
                    .accessibilityIdentifier(A11yID.TV.Onboarding.user(user.id))
                }
            }
        default:
            manualSignInForm
        }
    }

    private var selectedUserPasswordRow: some View {
        @Bindable var viewModel = viewModel
        return HStack(spacing: 24) {
            SecureField("Password", text: $viewModel.selectedUserPassword)
                .frame(width: 600)
            Button("Sign In") { Task { await viewModel.signInSelectedUser(using: appState) } }
                .disabled(viewModel.isSigningIn)
        }
    }

    private var manualSignInForm: some View {
        @Bindable var viewModel = viewModel
        return VStack(spacing: 24) {
            TextField("Username", text: $viewModel.username)
                .frame(width: 600)
            SecureField("Password", text: $viewModel.password)
                .frame(width: 600)
            Button("Sign In") { Task { await viewModel.signIn(using: appState) } }
                .disabled(!viewModel.canSubmit || viewModel.isSigningIn)
        }
    }
}
