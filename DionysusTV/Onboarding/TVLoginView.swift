import SwiftUI

/// Who's Watching?, on the shared `LoginViewModel`, in the prototype's layout:
/// the server's public users as circular lockups, then "Other". Choosing a
/// user follows `TVSignInRoute`: a user without a password signs in on Select,
/// anyone else goes to Quick Connect when the server has it, and to a password
/// otherwise. With no public users, the username and password form fills the
/// users area.
struct TVLoginView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = LoginViewModel()
    @FocusState private var focusedUserID: String?
    /// As on Find Your Server: the users arrive after the first focus pass, so
    /// the first one takes focus when they load, unless the person has moved.
    @State private var userMovedFocus = false

    @State private var quickConnectTarget: QuickConnectTarget?
    @State private var passwordUser: UserDto?
    @State private var showsManualSignIn = false
    /// Set by "Use Password Instead", and acted on once the Quick Connect
    /// cover has gone, so the next cover isn't presented while the first is
    /// still animating out.
    @State private var switchToPasswordFor: QuickConnectTarget?

    /// Who Quick Connect was opened for: a listed user, or nobody ("Other").
    struct QuickConnectTarget: Identifiable {
        let user: UserDto?
        var id: String { user?.id ?? "other" }
    }

    private var serverName: String {
        appState.sessionStore.serverConfiguration?.name ?? String(localized: "Your Server")
    }

    private var serverURL: URL? { appState.sessionStore.serverConfiguration?.baseURL }

    var body: some View {
        TVBrandBackground(photoURL: viewModel.splashscreenURL) {
            VStack(spacing: 0) {
                header
                    .padding(.top, 150)
                Spacer(minLength: 60)
                users
                if let error = viewModel.errorMessage {
                    Text(error).foregroundStyle(.red).padding(.top, 30)
                }
                Spacer(minLength: 60)
                Button("Change Server") { appState.changeServer() }
                    .font(.callout)
                    .accessibilityIdentifier(A11yID.TV.Onboarding.changeServer)
                    .padding(.bottom, 110)
            }
            .frame(maxWidth: .infinity)
            .ignoresSafeArea()
        }
        .task { await viewModel.load(using: appState) }
        .onChange(of: firstUserID) { _, firstID in
            guard !userMovedFocus, focusedUserID == nil, let firstID else { return }
            focusedUserID = firstID
        }
        .onMoveCommand { _ in userMovedFocus = true }
        .fullScreenCover(item: $quickConnectTarget, onDismiss: switchToPasswordIfAsked) { target in
            if let client = appState.apiClient {
                TVQuickConnectView(
                    client: client,
                    serverName: serverName,
                    user: target.user,
                    serverURL: serverURL,
                    onUsePassword: { switchToPasswordFor = target }
                )
            }
        }
        .fullScreenCover(item: $passwordUser) { user in
            TVPasswordSignInView(user: user, serverName: serverName, viewModel: viewModel)
        }
        .fullScreenCover(isPresented: $showsManualSignIn) {
            TVManualSignInView(serverName: serverName, viewModel: viewModel)
        }
    }

    private var header: some View {
        VStack(spacing: 22) {
            Image("DionysusGlyph")
                .resizable()
                .scaledToFit()
                .frame(width: 110, height: 110)
                .accessibilityHidden(true)
            Text("Who's Watching?")
                .font(.title2.bold())
                .accessibilityIdentifier(A11yID.TV.Onboarding.whosWatchingTitle)
            Text("Signing in to \(Text(serverName).bold())")
                .foregroundStyle(.secondary)
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
            HStack(spacing: 70) {
                ForEach(users) { user in
                    lockup(name: user.name) {
                        choose(user)
                    } avatar: {
                        UserAvatar(user: user, serverURL: serverURL, size: 230)
                    }
                    .focused($focusedUserID, equals: user.id)
                    .accessibilityIdentifier(A11yID.TV.Onboarding.user(user.id))
                }
                lockup(name: String(localized: "Other")) {
                    chooseOther()
                } avatar: {
                    Circle()
                        .fill(.white.opacity(0.14))
                        .frame(width: 230, height: 230)
                        .overlay {
                            Image(systemName: "plus")
                                .font(.system(size: 70, weight: .medium))
                                .accessibilityHidden(true)
                        }
                }
                .accessibilityIdentifier(A11yID.TV.Onboarding.otherUser)
            }
        default:
            TVManualSignInForm(viewModel: viewModel)
        }
    }

    /// A circular lockup: the avatar lifts on focus, the name sits below it.
    private func lockup(
        name: String,
        action: @escaping () -> Void,
        @ViewBuilder avatar: () -> some View
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 26) {
                avatar()
                    .contentShape(.hoverEffect, Circle())
                    .hoverEffect(.highlight)
                Text(verbatim: name).font(.callout.weight(.semibold))
            }
        }
        .buttonStyle(.borderless)
        .buttonBorderShape(.circle)
    }

    private func choose(_ user: UserDto) {
        switch TVSignInRoute.forUser(user, quickConnectAvailable: viewModel.isQuickConnectAvailable) {
        case .signInNow: Task { await viewModel.choose(user, using: appState) }
        case .quickConnect: quickConnectTarget = QuickConnectTarget(user: user)
        case .password: passwordUser = user
        }
    }

    /// "Other": Quick Connect when the server has it, as for a listed user;
    /// the username and password form otherwise.
    private func chooseOther() {
        if viewModel.isQuickConnectAvailable {
            quickConnectTarget = QuickConnectTarget(user: nil)
        } else {
            showsManualSignIn = true
        }
    }

    private func switchToPasswordIfAsked() {
        guard let target = switchToPasswordFor else { return }
        switchToPasswordFor = nil
        if let user = target.user {
            passwordUser = user
        } else {
            showsManualSignIn = true
        }
    }
}

/// The username and password form, for "Other" and for a server that lists
/// no users: one column, 600pt wide.
struct TVManualSignInForm: View {
    @Environment(AppState.self) private var appState
    let viewModel: LoginViewModel

    var body: some View {
        @Bindable var viewModel = viewModel
        VStack(spacing: 24) {
            TextField("Username", text: $viewModel.username)
                .frame(width: 600)
            SecureField("Password", text: $viewModel.password)
                .frame(width: 600)
            Button("Sign In") { Task { await viewModel.signIn(using: appState) } }
                .disabled(!viewModel.canSubmit || viewModel.isSigningIn)
        }
    }
}

/// "Other"'s form on its own screen, over the brand background.
private struct TVManualSignInView: View {
    @Environment(\.dismiss) private var dismiss
    let serverName: String
    let viewModel: LoginViewModel

    var body: some View {
        TVBrandBackground {
            VStack(spacing: 40) {
                VStack(spacing: 12) {
                    Text("Sign In").font(.title2.bold())
                    Text(verbatim: serverName).foregroundStyle(.secondary)
                }
                TVManualSignInForm(viewModel: viewModel)
                if let error = viewModel.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
                Button("Cancel") { dismiss() }
            }
        }
    }
}
