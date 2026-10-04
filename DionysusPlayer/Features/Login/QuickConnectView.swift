import SwiftUI

/// Shows a Quick Connect code for the user to approve from another client,
/// and signs in once they have. Presented as a sheet from `LoginView`.
///
/// Success needs no handling here: `AppState.signInWithQuickConnect` moves
/// the phase to `.main`, and `RootView` replaces the whole login screen —
/// this sheet with it.
struct QuickConnectView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: QuickConnectViewModel
    /// Bumped by "Get New Code" to restart `.task(id:)`, which cancels
    /// nothing (the previous run has already ended) and starts a new code.
    @State private var attempt = 0

    let serverName: String

    init(client: JellyfinAPIClient, serverName: String) {
        _viewModel = State(initialValue: QuickConnectViewModel(client: client))
        self.serverName = serverName
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Text("On a device already signed in to \(serverName), open Quick Connect and enter this code.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    codeDisplay

                    status
                }
                // Fills the column so the stack centers in it. Left to size
                // itself, it's only as wide as the wrapped instructions, and
                // `signInColumn()` — which keeps the login forms leading-
                // aligned — puts it against the leading edge.
                .frame(maxWidth: .infinity)
                .padding(SignInLayout.contentPadding)
                .signInColumn()
            }
            .navigationTitle("Quick Connect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .accessibilityIdentifier(A11yID.QuickConnect.cancelButton)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task(id: attempt) {
            await viewModel.run { secret in
                try await appState.signInWithQuickConnect(secret: secret)
            }
        }
        .onChange(of: viewModel.state) { _, state in
            if case .failed(let message) = state {
                AccessibilityNotification.Announcement(message).post()
            }
        }
    }

    /// Always laid out, with a placeholder while there's no code yet, so the
    /// sheet doesn't jump when the code arrives.
    @ViewBuilder
    private var codeDisplay: some View {
        let code = currentCode
        Text(code ?? "------")
            .font(.system(size: 44, weight: .semibold, design: .monospaced))
            .tracking(Self.codeTracking)
            // Tracking also follows the last digit, so the visible digits
            // sit left of centre by that much; matching it on the leading
            // side balances them.
            .padding(.leading, Self.codeTracking)
            .minimumScaleFactor(0.5)
            .lineLimit(1)
            .foregroundStyle(code == nil ? .tertiary : .primary)
            .textSelection(.enabled)
            .accessibilityLabel(code.map(QuickConnectViewModel.spokenCode) ?? String(localized: "Requesting a code"))
            .accessibilityIdentifier(A11yID.QuickConnect.code)
    }

    private static let codeTracking: CGFloat = 6

    private var currentCode: String? {
        switch viewModel.state {
        case .waiting(let code): code
        default: nil
        }
    }

    @ViewBuilder
    private var status: some View {
        switch viewModel.state {
        case .requesting:
            ProgressView()
        case .waiting:
            progress("Waiting for approval…")
        case .authorizing:
            progress("Signing In…")
        case .expired:
            retry(message: String(localized: "This code has expired."))
        case .failed(let message):
            retry(message: message)
        }
    }

    /// The spinner is hidden from VoiceOver rather than combined with the
    /// text: combining makes the row one activity indicator the height of a
    /// footnote, which the accessibility audit flags as too small a target
    /// for something it reads as interactive. The text says it all anyway.
    private func progress(_ text: LocalizedStringKey) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .accessibilityHidden(true)
            Text(text)
                .foregroundStyle(.secondary)
        }
        .font(.footnote)
    }

    private func retry(message: String) -> some View {
        VStack(spacing: 12) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                // See `ServerSetupView` for what this colour change does and
                // doesn't change.
                .foregroundStyle(Color.dionysusPrimary)
                .accessibilityIdentifier(A11yID.QuickConnect.errorMessage)
            Button("Get New Code") { attempt += 1 }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier(A11yID.QuickConnect.newCodeButton)
        }
    }
}
