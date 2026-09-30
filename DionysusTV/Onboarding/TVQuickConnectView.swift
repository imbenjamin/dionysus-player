import SwiftUI

/// Quick Connect on the shared `QuickConnectViewModel`, in the prototype's
/// layout: who is signing in on the left, the code to approve on another
/// signed-in device on the right. The copy names no menu path, because where
/// Quick Connect lives differs between Jellyfin clients, and doesn't promise
/// which account signs in: that's whichever one approves the code.
struct TVQuickConnectView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: QuickConnectViewModel
    /// Bumped by "Get New Code" to restart `.task(id:)`, as on iOS.
    @State private var attempt = 0
    @FocusState private var usePasswordFocused: Bool
    let serverName: String
    let user: UserDto?
    let serverURL: URL?
    let onUsePassword: (() -> Void)?

    init(client: JellyfinAPIClient, serverName: String, user: UserDto?, serverURL: URL?, onUsePassword: (() -> Void)?) {
        _viewModel = State(initialValue: QuickConnectViewModel(client: client))
        self.serverName = serverName
        self.user = user
        self.serverURL = serverURL
        self.onUsePassword = onUsePassword
    }

    var body: some View {
        TVBrandBackground {
            TVOnboardingPanes {
                VStack(spacing: 28) {
                    if let user {
                        UserAvatar(user: user, serverURL: serverURL, size: 260)
                        Text(verbatim: user.name).font(.title3.bold())
                    } else {
                        Image("DionysusGlyph")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 260, height: 260)
                            .accessibilityHidden(true)
                    }
                    Text(verbatim: serverName).foregroundStyle(.secondary)
                }
            } task: {
                VStack(alignment: .leading, spacing: 40) {
                    Text("Sign In with Quick Connect").font(.title2.bold())
                    Text("On a device already signed in to \(serverName), open Quick Connect and enter this code.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 800, alignment: .leading)
                    panel
                    HStack(spacing: 26) {
                        if let onUsePassword {
                            Button("Use Password Instead") {
                                onUsePassword()
                                dismiss()
                            }
                            .focused($usePasswordFocused)
                            .accessibilityIdentifier(A11yID.TV.Onboarding.usePassword)
                        }
                        Button("Cancel") { dismiss() }
                    }
                }
            }
        }
        // The code needs no press, so the one thing to press is the way out
        // to a password; Cancel is beside it.
        .defaultFocus($usePasswordFocused, true)
        .task(id: attempt) {
            await viewModel.run { secret in
                _ = try await appState.signInWithQuickConnect(secret: secret)
            }
        }
    }

    private var panel: some View {
        VStack(spacing: 30) {
            switch viewModel.state {
            case .waiting(let code):
                HStack(spacing: 16) {
                    ForEach(Array(code.enumerated()), id: \.offset) { _, character in
                        Text(verbatim: String(character))
                            .font(.system(size: 84, weight: .bold))
                            .monospacedDigit()
                            .frame(width: 104, height: 136)
                            .background(RoundedRectangle(cornerRadius: 22).fill(.white.opacity(0.12)))
                    }
                }
                // Read as one piece of text, not six tiles. A representation
                // rather than `.accessibilityElement(children: .ignore)`, which
                // exposes a generic element instead of static text.
                .accessibilityRepresentation { Text(verbatim: code) }
                .accessibilityIdentifier(A11yID.TV.Onboarding.quickConnectCode)
                HStack(spacing: 14) {
                    Circle().fill(Color.dionysusGold).frame(width: 14, height: 14)
                        .accessibilityHidden(true)
                    Text("Waiting for approval").foregroundStyle(.secondary)
                }
            case .expired:
                Text("The code expired.")
                Button("Get New Code") { attempt += 1 }
            case .failed(let message):
                Text(message).foregroundStyle(.red)
            default:
                ProgressView()
            }
        }
        .padding(50)
        .frame(width: 800)
        .frame(minHeight: 300)
        .glassEffect(.regular, in: .rect(cornerRadius: 40))
    }
}
