import SwiftUI

/// Signing in as someone the server doesn't list — an admin can hide any user
/// from the login screen — by username and password, or with Quick Connect.
///
/// Quick Connect keeps its own sheet (`QuickConnectView`): choosing it here
/// closes this one first and `LoginView` opens that from this one's
/// `onDismiss`, since swapping one presented sheet for another while it's
/// still up doesn't reliably present the second.
struct OtherUserSheet: View {
    private enum Field {
        case username
        case password
    }

    @Bindable var viewModel: LoginViewModel
    let serverName: String
    let isQuickConnectAvailable: Bool
    let onChooseQuickConnect: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Username", text: $viewModel.username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focusedField, equals: .username)
                        .onSubmit { focusedField = .password }
                        .accessibilityLabel("Username")
                        .accessibilityIdentifier(A11yID.Login.usernameField)
                    SecureField("Password (optional)", text: $viewModel.password)
                        .textContentType(.password)
                        .submitLabel(.go)
                        .focused($focusedField, equals: .password)
                        .onSubmit(signIn)
                        .accessibilityLabel("Password (optional)")
                        .accessibilityIdentifier(A11yID.Login.passwordField)
                } footer: {
                    if let errorMessage = viewModel.errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            // See `Color.dionysusMagentaHighContrast` for the
                            // measured contrast, and why the dynamic colour.
                            .foregroundStyle(Color.dionysusPrimary)
                            .accessibilityIdentifier(A11yID.Login.errorMessage)
                    }
                }

                if isQuickConnectAvailable {
                    Section {
                        Button("Sign In with Quick Connect", systemImage: "link", action: onChooseQuickConnect)
                            .accessibilityIdentifier(A11yID.Login.quickConnectButton)
                    } footer: {
                        Text("Approve this device from another app already signed in to \(serverName).")
                    }
                }
            }
            .navigationTitle("Sign In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Icon and title both: a title-only item isn't presented in
                // the vertical toolbars sheets can get on a foldable's outer
                // display.
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier(A11yID.Login.otherUserCancelButton)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if viewModel.isSigningIn {
                        ProgressView()
                    } else {
                        Button("Sign In", systemImage: "checkmark", action: signIn)
                            .disabled(!viewModel.canSubmit)
                            .keyboardShortcut(.defaultAction)
                            .accessibilityIdentifier(A11yID.Login.signInButton)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationSizing(.form)
        // A sheet doesn't inherit `OnboardingFlowView`'s scoped appearance.
        .preferredColorScheme(.dark)
        .onAppear {
            viewModel.clearSelection()
            focusedField = viewModel.username.isEmpty ? .username : .password
        }
    }

    private func signIn() {
        Task { await viewModel.signIn(using: appState) }
    }
}
