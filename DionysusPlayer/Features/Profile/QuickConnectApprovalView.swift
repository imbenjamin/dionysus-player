import SwiftUI

/// Enter another device's Quick Connect code to sign it in as this user.
/// Pushed from `AccountDetailsContent` — inside the Account sheet on iPhone,
/// the Profile detail column on iPad.
struct QuickConnectApprovalView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: QuickConnectApprovalViewModel
    @FocusState private var isCodeFocused: Bool

    init(client: JellyfinAPIClient, userName: String, serverName: String) {
        _viewModel = State(initialValue: QuickConnectApprovalViewModel(
            client: client, userName: userName, serverName: serverName
        ))
    }

    var body: some View {
        ScrollView {
            Group {
                if viewModel.state == .approved {
                    approved
                } else {
                    entry
                }
            }
            // Fills the column so the stack centres in it rather than sitting
            // against `signInColumn()`'s leading edge (see `QuickConnectView`).
            .frame(maxWidth: .infinity)
            .padding(SignInLayout.contentPadding)
            .signInColumn()
        }
        .navigationTitle("Quick Connect")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { isCodeFocused = true }
        .sensoryFeedback(.success, trigger: viewModel.state == .approved)
        .onChange(of: viewModel.state) { _, state in
            if case .failed(let message) = state {
                AccessibilityNotification.Announcement(message).post()
            }
        }
    }

    private var entry: some View {
        VStack(spacing: 24) {
            Text("On the device you're signing in on, choose Quick Connect to get a code, then enter it here.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Code", text: Binding(get: { viewModel.code }, set: { viewModel.setCode($0) }))
                .font(.system(size: 34, weight: .semibold, design: .monospaced))
                .multilineTextAlignment(.center)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .autocorrectionDisabled()
                .padding(.vertical, 8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                .frame(maxWidth: 260)
                .focused($isCodeFocused)
                .disabled(viewModel.state == .submitting)
                // No visible label beyond the placeholder, which disappears
                // on the first digit — see `LoginView`'s fields.
                .accessibilityLabel("Quick Connect code")
                .accessibilityIdentifier(A11yID.QuickConnectApproval.codeField)

            Button {
                isCodeFocused = false
                Task { await viewModel.authorize() }
            } label: {
                Group {
                    if viewModel.state == .submitting {
                        ProgressView()
                    } else {
                        Text("Authorize")
                    }
                }
                .frame(maxWidth: 260)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!viewModel.canSubmit)
            .accessibilityLabel("Authorize")
            .accessibilityValue(viewModel.state == .submitting ? String(localized: "Authorizing") : "")
            .accessibilityIdentifier(A11yID.QuickConnectApproval.authorizeButton)

            if case .failed(let message) = viewModel.state {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    // See `ServerSetupView` for what this colour change does
                    // and doesn't change.
                    .foregroundStyle(Color.dionysusPrimary)
                    .accessibilityIdentifier(A11yID.QuickConnectApproval.errorMessage)
            }
        }
    }

    private var approved: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.dionysusHighlight)
                .accessibilityHidden(true)
            Text("Device Signed In")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
                // On the heading, not the stack: an identifier on a container
                // can overwrite its descendants' own (see `A11yID`).
                .accessibilityIdentifier(A11yID.QuickConnectApproval.successMessage)
            Text("The other device is now signed in as \(viewModel.userName). It can take a few seconds to finish.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 8)
                .accessibilityIdentifier(A11yID.QuickConnectApproval.doneButton)
        }
    }
}
