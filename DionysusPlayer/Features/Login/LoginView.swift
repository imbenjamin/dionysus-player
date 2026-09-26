import SwiftUI

/// Sign-in, built around picking who's watching from the server's public user
/// list (`/Users/Public`). A user without a password is one tap. One with a
/// password is asked for it — in a panel under the grid on a phone, in a
/// popover anchored to their avatar on iPad. "Other" covers hidden users and
/// Quick Connect. A server that lists nobody gets a plain username and
/// password form instead.
///
/// On success `AppState` remembers the credentials, so launch can sign in
/// again silently; `RootView` then fades this whole flow out for the app.
struct LoginView: View {
    private enum Field {
        case username
        case password
    }

    @Environment(AppState.self) private var appState
    @Environment(\.onboardingLayout) private var layout
    @Environment(\.onboardingWindowSize) private var windowSize
    @State private var viewModel = LoginViewModel()
    @FocusState private var focusedField: Field?
    @State private var isShowingOtherUser = false
    @State private var isShowingQuickConnect = false
    /// Set when "Other" hands over to Quick Connect: the second sheet goes up
    /// only once the first is fully down, from its `onDismiss`.
    @State private var opensQuickConnectOnDismiss = false

    private var serverName: String {
        appState.sessionStore.serverConfiguration?.name ?? String(localized: "Your Server")
    }

    var body: some View {
        ZStack {
            OnboardingScreen(centersCompact: true) {
                header
            } content: {
                content
            } actions: {
                EmptyView()
            }
            .opacity(viewModel.signingInUser == nil ? 1 : 0)
            .allowsHitTesting(viewModel.signingInUser == nil)

            if let user = viewModel.signingInUser {
                signingIn(as: user)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.smooth(duration: 0.4), value: viewModel.signingInUser)
        .animation(.smooth(duration: 0.35), value: viewModel.selectedUser)
        .animation(.smooth, value: viewModel.usersState)
        .preference(key: OnboardingBackdropKey.self, value: viewModel.splashscreenURL)
        .task { await viewModel.load(using: appState) }
        .onAppear {
            // Back here after signing out: the name is already known.
            if viewModel.username.isEmpty, let username = appState.sessionStore.credentials?.username {
                viewModel.username = username
            }
        }
        .onChange(of: viewModel.errorMessage) { _, message in
            guard let message else { return }
            AccessibilityNotification.Announcement(message).post()
        }
        .sheet(isPresented: $isShowingOtherUser, onDismiss: {
            guard opensQuickConnectOnDismiss else { return }
            opensQuickConnectOnDismiss = false
            isShowingQuickConnect = true
        }) {
            OtherUserSheet(
                viewModel: viewModel,
                serverName: serverName,
                isQuickConnectAvailable: viewModel.isQuickConnectAvailable
            ) {
                opensQuickConnectOnDismiss = true
                isShowingOtherUser = false
            }
        }
        .sheet(isPresented: $isShowingQuickConnect) {
            if let client = appState.apiClient {
                QuickConnectView(client: client, serverName: serverName)
                    .preferredColorScheme(.dark)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: layout.isRegular ? 16 : 10) {
            DionysusGlassGlyph()
                .onboardingGlyph()
                .frame(width: layout.headerGlyph, height: layout.headerGlyph)
            if case .unavailable = viewModel.usersState {
                OnboardingTitle("Sign In")
            } else {
                OnboardingTitle("Who's Watching?")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { serverLine }
                VStack(spacing: 0) { serverLine }
            }
            .font(layout.isRegular ? .title3 : .subheadline)
        }
        .multilineTextAlignment(.center)
    }

    @ViewBuilder
    private var serverLine: some View {
        Text("Signing in to **\(serverName)**")
            .foregroundStyle(.white.opacity(0.85))
        Button {
            appState.changeServer()
        } label: {
            Text("Change Server")
                .fontWeight(.semibold)
                .underline()
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .foregroundStyle(.white)
        .hoverEffect(.highlight)
        .disabled(viewModel.isSigningIn)
        .accessibilityIdentifier(A11yID.Login.changeServerButton)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 32) {
            switch viewModel.usersState {
            case .loading:
                ProgressView()
                    .tint(.white)
                    .frame(minHeight: 120)
            case .loaded(let users):
                userGrid(users)
                if layout == .compact, let user = viewModel.selectedUser {
                    passwordPanel(for: user)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if viewModel.selectedUser == nil, let errorMessage = viewModel.errorMessage {
                    errorLabel(errorMessage)
                }
            case .unavailable:
                manualForm
            }

            if let disclaimer = viewModel.disclaimer {
                Text(disclaimer)
                    .font(layout.isRegular ? .subheadline : .footnote)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    // A darker scrim than the glass gives, because a server's
                    // artwork can put something bright directly behind it.
                    .background(.black.opacity(0.35), in: .rect(cornerRadius: 12))
                    .accessibilityIdentifier(A11yID.Login.disclaimer)
            }
        }
    }

    private var isShortLandscape: Bool {
        OnboardingLayout.isShortLandscape(layout, windowSize: windowSize)
    }
    private var avatarSize: CGFloat { isShortLandscape ? 96 : layout.avatar }
    private var tileWidth: CGFloat { isShortLandscape ? 116 : layout.tileWidth }

    private func userGrid(_ users: [UserDto]) -> some View {
        CenteredFlowLayout(itemWidth: tileWidth, spacing: 20, lineSpacing: layout.isRegular ? 32 : 24) {
            ForEach(users) { user in
                userTile(user)
            }
            otherUserTile
        }
    }

    private func userTile(_ user: UserDto) -> some View {
        let isSelected = viewModel.selectedUser?.id == user.id
        let isDimmed = viewModel.selectedUser != nil && !isSelected
        return Button {
            focusedField = nil
            Task {
                await viewModel.choose(user, using: appState)
                if viewModel.selectedUser?.id == user.id, layout == .compact {
                    focusedField = .password
                }
            }
        } label: {
            VStack(spacing: 10) {
                UserAvatar(user: user, serverURL: appState.sessionStore.serverConfiguration?.baseURL, size: avatarSize)
                    .overlay {
                        Circle()
                            .strokeBorder(.white, lineWidth: 3)
                            .padding(-6)
                            .opacity(isSelected ? 1 : 0)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if user.hasPassword != false {
                            Image(systemName: "lock.fill")
                                .font(layout.isRegular ? .footnote.weight(.bold) : .caption2.weight(.bold))
                                .frame(width: layout.isRegular ? 34 : 26, height: layout.isRegular ? 34 : 26)
                                .onboardingGlass(in: Circle())
                                .offset(x: 2, y: 2)
                                .accessibilityHidden(true)
                        }
                    }
                    .scaleEffect(isSelected ? 1.06 : 1)
                    .hoverEffect(.lift)
                Text(user.name)
                    .font(layout.isRegular ? .title3.weight(.semibold) : .subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isDimmed ? 0.45 : 1)
        .disabled(viewModel.isSigningIn)
        .popover(
            isPresented: Binding(
                get: { layout.isRegular && isSelected },
                set: { if !$0 { viewModel.clearSelection() } }
            ),
            // Below the avatar, pointing up at it, so it never covers the
            // title or the server line above the grid.
            arrowEdge: .top
        ) {
            passwordPopover(for: user)
        }
        .accessibilityLabel(user.name)
        .accessibilityValue(user.hasPassword == false ? "" : String(localized: "Password required"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(A11yID.Login.userTile(user.id))
    }

    private var otherUserTile: some View {
        Button {
            viewModel.clearSelection()
            focusedField = nil
            isShowingOtherUser = true
        } label: {
            VStack(spacing: 10) {
                Image(systemName: "ellipsis")
                    .font(layout.isRegular ? .title.weight(.semibold) : .title2.weight(.semibold))
                    .frame(width: avatarSize, height: avatarSize)
                    .onboardingGlass(in: Circle())
                    .hoverEffect(.lift)
                    .accessibilityHidden(true)
                Text("Other")
                    .font(layout.isRegular ? .title3.weight(.semibold) : .subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(viewModel.selectedUser == nil ? 1 : 0.45)
        .disabled(viewModel.isSigningIn)
        .accessibilityLabel("Sign In Another Way")
        .accessibilityIdentifier(A11yID.Login.otherUserButton)
    }

    // MARK: - Password

    /// The phone's password step: under the grid, where the keyboard pushes
    /// it into view.
    private func passwordPanel(for user: UserDto) -> some View {
        VStack(spacing: 14) {
            passwordField(for: user)
            if let errorMessage = viewModel.errorMessage {
                errorLabel(errorMessage)
            }
            OnboardingPrimaryButton(title: "Sign In", isBusy: viewModel.isSigningIn) {
                Task { await viewModel.signInSelectedUser(using: appState) }
            }
            .accessibilityIdentifier(A11yID.Login.signInButton)
        }
        .padding(16)
        .onboardingGlass(in: .rect(cornerRadius: 26))
    }

    /// iPad's password step: a popover anchored to the avatar that was
    /// tapped — the HIG's container for one small, focused task.
    private func passwordPopover(for user: UserDto) -> some View {
        VStack(spacing: 16) {
            Text("Enter the password for \(user.name)")
                .font(.headline)
                .multilineTextAlignment(.center)
            passwordField(for: user)
            if let errorMessage = viewModel.errorMessage {
                errorLabel(errorMessage)
            }
            OnboardingPrimaryButton(title: "Sign In", isBusy: viewModel.isSigningIn, isDefaultAction: true) {
                Task { await viewModel.signInSelectedUser(using: appState) }
            }
            .accessibilityIdentifier(A11yID.Login.signInButton)
        }
        .padding(24)
        .frame(width: 340)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .onAppear { focusedField = .password }
    }

    private func passwordField(for user: UserDto) -> some View {
        // Never gated on being non-empty: `HasPassword: true` doesn't mean a
        // password is needed (see `JellyfinAPIClient.publicUsers()`).
        SecureField("Password", text: $viewModel.selectedUserPassword)
            .textContentType(.password)
            .submitLabel(.go)
            .focused($focusedField, equals: .password)
            .onSubmit { Task { await viewModel.signInSelectedUser(using: appState) } }
            .padding(.horizontal, 16)
            .frame(minHeight: 50)
            .background(.white.opacity(0.12), in: .rect(cornerRadius: 14))
            .accessibilityLabel("Password for \(user.name)")
            .accessibilityIdentifier(A11yID.Login.passwordField)
    }

    private func errorLabel(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(A11yID.Login.errorMessage)
    }

    // MARK: - Fallback form

    /// For a server that lists nobody — every user hidden from its login
    /// screen — or couldn't be asked.
    private var manualForm: some View {
        VStack(spacing: 14) {
            VStack(spacing: 0) {
                TextField("Username", text: $viewModel.username)
                    // Without an explicit content type the Passwords app has
                    // only placeholder heuristics to go on, which decide
                    // whether it offers to save the pair after sign-in.
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($focusedField, equals: .username)
                    .onSubmit { focusedField = .password }
                    .frame(minHeight: 50)
                    // The placeholder disappears on the first keystroke,
                    // leaving VoiceOver nothing to say what the field is.
                    .accessibilityLabel("Username")
                    .accessibilityIdentifier(A11yID.Login.usernameField)
                Divider()
                SecureField("Password (optional)", text: $viewModel.password)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .focused($focusedField, equals: .password)
                    .onSubmit { Task { await viewModel.signIn(using: appState) } }
                    .frame(minHeight: 50)
                    .accessibilityLabel("Password (optional)")
                    .accessibilityIdentifier(A11yID.Login.passwordField)
            }
            .padding(.horizontal, 16)
            .background(.white.opacity(0.12), in: .rect(cornerRadius: 16))

            if let errorMessage = viewModel.errorMessage {
                errorLabel(errorMessage)
            }

            OnboardingPrimaryButton(
                title: "Sign In",
                isBusy: viewModel.isSigningIn,
                isEnabled: viewModel.canSubmit || viewModel.isSigningIn,
                isDefaultAction: true
            ) {
                Task { await viewModel.signIn(using: appState) }
            }
            .accessibilityIdentifier(A11yID.Login.signInButton)

            if viewModel.isQuickConnectAvailable {
                OnboardingSecondaryButton(title: "Sign In with Quick Connect", systemImage: "link") {
                    focusedField = nil
                    isShowingQuickConnect = true
                }
                .disabled(viewModel.isSigningIn)
                .accessibilityIdentifier(A11yID.Login.quickConnectButton)
            }
        }
        .padding(16)
        .onboardingGlass(in: .rect(cornerRadius: 26))
        .frame(maxWidth: SignInLayout.credentialsWidth)
    }

    // MARK: - Signing in

    private func signingIn(as user: UserDto) -> some View {
        VStack(spacing: 20) {
            UserAvatar(
                user: user,
                serverURL: appState.sessionStore.serverConfiguration?.baseURL,
                size: layout.isRegular ? 160 : 120
            )
            VStack(spacing: 8) {
                Text("Signing in as \(user.name)")
                    .font(layout.isRegular ? .title.bold() : .title2.bold())
                ProgressView()
                    .tint(.white)
                    .accessibilityHidden(true)
            }
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .accessibilityElement(children: .combine)
    }
}

/// A user's Jellyfin profile picture, over their initial on a colour derived
/// from their id — which is also what shows while the picture loads, or for a
/// user who never set one. The picture needs no sign-in to fetch.
struct UserAvatar: View {
    let user: UserDto
    let serverURL: URL?
    var size: CGFloat = 84

    @State private var image: UIImage?

    private var imageURL: URL? {
        guard let serverURL, let tag = user.primaryImageTag else { return nil }
        return ImageURLBuilder(baseURL: serverURL, accessToken: nil)
            .userImageURL(userID: user.id, tag: tag, maxWidth: Int(size * 3))
    }

    /// A stable hue per user, so the same person is the same colour every time.
    private var hue: Double {
        let sum = user.id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return Double(sum % 360) / 360
    }

    var body: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [
                        Color(hue: hue, saturation: 0.55, brightness: 0.95),
                        Color(hue: hue, saturation: 0.75, brightness: 0.55)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                // A person's initial, not translated.
                Text(verbatim: user.name.prefix(1).uppercased())
                    .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .clipShape(Circle())
                        .transition(.opacity)
                }
            }
            .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
            .task(id: imageURL) {
                guard let imageURL, let loaded = try? await RemoteImageLoader.shared.image(for: imageURL) else { return }
                withAnimation(.easeInOut(duration: 0.3)) { image = loaded }
            }
    }
}

#Preview {
    ZStack {
        OnboardingBackground()
        LoginView()
    }
    .environment(AppState())
    .environment(\.colorScheme, .dark)
    .foregroundStyle(.white)
}
