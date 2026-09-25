import Foundation
import Observation

@MainActor
@Observable
final class LoginViewModel {
    var username = ""
    var password = ""
    private(set) var isSigningIn = false
    private(set) var errorMessage: String?
    /// Whether to offer "Sign In with Quick Connect". Starts `false` and
    /// stays there on any failure to ask, so a server that can't answer
    /// never shows a button that would only fail.
    private(set) var isQuickConnectAvailable = false

    var canSubmit: Bool {
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSigningIn
    }

    func loadQuickConnectAvailability(using appState: AppState) async {
        guard let client = appState.apiClient else { return }
        isQuickConnectAvailable = (try? await client.quickConnectEnabled()) ?? false
    }

    func signIn(using appState: AppState) async {
        errorMessage = nil
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            try await appState.signIn(username: username, password: password)
        } catch {
            errorMessage = String(localized: "Couldn't sign in. Check your username and password.")
        }
    }
}
