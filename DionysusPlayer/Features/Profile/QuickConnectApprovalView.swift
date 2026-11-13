import SwiftUI

/// Enter another device's Quick Connect code to sign it in as this user.
/// Pushed from `AccountDetailsContent` — inside the Account sheet on iPhone,
/// the Profile detail column on iPad.
struct QuickConnectApprovalView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: QuickConnectApprovalViewModel
    @FocusState private var isCodeFocused: Bool

    /// `code` fills the field, as a `dionysus://quickconnect/approve` link
    /// does (#406), without submitting it: approving signs a device in, so
    /// that stays a tap.
    init(client: JellyfinAPIClient, userName: String, serverName: String, code: String? = nil) {
        let viewModel = QuickConnectApprovalViewModel(client: client, userName: userName, serverName: serverName)
        if let code { viewModel.setCode(code) }
        _viewModel = State(initialValue: viewModel)
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
                .accessibilityIdentifier(A11yID.QuickConnectApproval.instructions)

            // The last digit submits (see `setCode`); Authorize stays for
            // trying the same code again after an error.
            TextField("Code", text: Binding(get: { viewModel.code }, set: { if viewModel.setCode($0) { authorize() } }))
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

            Button(action: authorize) {
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

    /// Drops focus first, which also closes the iPad's number-pad popover.
    ///
    /// In a task, not straight away: from the last digit this runs inside
    /// the keypad's own key handling, and dropping focus there crashed the
    /// app on iPadOS 27.2 every time the field changed again before the
    /// popover had finished closing (a wrong code re-enabling it, say):
    /// `EXC_BAD_ACCESS` in `UITrackingElementWindowController
    /// changeToInputViewSet:`, from the keyboard's placement animation
    /// (TQ-20). The next turn of the main actor is enough.
    private func authorize() {
        Task {
            isCodeFocused = false
            await viewModel.authorize()
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
