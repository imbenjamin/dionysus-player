import Foundation
import Observation

@MainActor
@Observable
final class LoginViewModel {
    var username = ""
    var password = ""
    private(set) var isSigningIn = false
    private(set) var errorMessage: String?

    var canSubmit: Bool {
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSigningIn
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
