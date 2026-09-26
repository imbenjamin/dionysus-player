import Foundation
import Observation

@MainActor
@Observable
final class LoginViewModel {
    /// Where the server's public user list has got to. The screen is built
    /// around it — "Who's Watching?" — and falls back to a plain username and
    /// password form when there's nothing to pick from.
    enum UsersState: Equatable {
        case loading
        case loaded([UserDto])
        /// The server lists nobody (every user hidden from its login screen),
        /// or couldn't be asked.
        case unavailable
    }

    // The manual form: the "Other" sheet, or the screen itself when
    // `usersState` is `.unavailable`.
    var username = ""
    var password = ""

    /// The typed password for `selectedUser`.
    var selectedUserPassword = ""
    /// A listed user whose password is being asked for.
    private(set) var selectedUser: UserDto?
    /// The listed user a sign-in is under way for, which the screen shows in
    /// place of the grid.
    private(set) var signingInUser: UserDto?

    private(set) var usersState: UsersState = .loading
    private(set) var isSigningIn = false
    private(set) var errorMessage: String?
    /// Whether to offer "Sign In with Quick Connect". Starts `false` and
    /// stays there on any failure to ask, so a server that can't answer
    /// never shows a button that would only fail.
    private(set) var isQuickConnectAvailable = false
    /// The server's login disclaimer, as plain text.
    private(set) var disclaimer: String?
    /// The server's login artwork, when it has turned one on.
    private(set) var splashscreenURL: URL?

    var canSubmit: Bool {
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSigningIn
    }

    /// Everything the screen asks the server for, concurrently. None of it
    /// can fail the screen: each part falls back to the plainer version.
    func load(using appState: AppState) async {
        guard let client = appState.apiClient else {
            usersState = .unavailable
            return
        }
        async let quickConnect = (try? await client.quickConnectEnabled()) ?? false
        async let users = try? await client.publicUsers()
        async let branding = try? await client.brandingConfiguration()

        isQuickConnectAvailable = await quickConnect
        let listed = await users ?? []
        usersState = listed.isEmpty ? .unavailable : .loaded(listed)

        let configuration = await branding
        disclaimer = configuration?.loginDisclaimer.flatMap(LoginDisclaimer.plainText(from:))
        if configuration?.splashscreenEnabled == true, let baseURL = appState.sessionStore.serverConfiguration?.baseURL {
            splashscreenURL = ImageURLBuilder(baseURL: baseURL, accessToken: nil).splashscreenURL()
        }
    }

    func loadQuickConnectAvailability(using appState: AppState) async {
        guard let client = appState.apiClient else { return }
        isQuickConnectAvailable = (try? await client.quickConnectEnabled()) ?? false
    }

    /// A tap on a listed user. `hasPassword == false` is the one conclusive
    /// answer (see `JellyfinAPIClient.publicUsers()`), so only that signs in
    /// at once; anyone else is asked, and may still submit an empty password.
    func choose(_ user: UserDto, using appState: AppState) async {
        errorMessage = nil
        if user.hasPassword == false {
            selectedUser = nil
            await signIn(as: user, password: "", using: appState)
        } else {
            selectedUser = selectedUser?.id == user.id ? nil : user
            selectedUserPassword = ""
        }
    }

    func clearSelection() {
        selectedUser = nil
        selectedUserPassword = ""
        errorMessage = nil
    }

    /// Signs in as `selectedUser` with the password typed for them. A wrong
    /// password leaves them selected, with the error beside the field.
    func signInSelectedUser(using appState: AppState) async {
        guard let user = selectedUser else { return }
        await signIn(as: user, password: selectedUserPassword, using: appState)
    }

    /// The manual form.
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

    private func signIn(as user: UserDto, password: String, using appState: AppState) async {
        guard !isSigningIn else { return }
        errorMessage = nil
        isSigningIn = true
        signingInUser = user
        defer { isSigningIn = false }
        do {
            try await appState.signIn(username: user.name, password: password)
            // `signingInUser` stays set: `RootView` is already fading this
            // screen out, and clearing it would flash the grid back mid-fade.
        } catch {
            signingInUser = nil
            errorMessage = user.hasPassword == false
                // Nothing the user typed to blame: a passwordless account was
                // refused, or the server couldn't be reached.
                ? String(localized: "Couldn't sign in as \(user.name). Try again.")
                : String(localized: "Couldn't sign in. Check the password and try again.")
        }
    }
}

/// The server's login disclaimer, reduced to plain text. Jellyfin passes it to
/// its web client as HTML — the demo server's carries `<br/>` alongside raw
/// newlines — and a line of stray markup is worse than none.
enum LoginDisclaimer {
    static func plainText(from html: String) -> String? {
        var text = html.replacingOccurrences(
            of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        // In order, `&amp;` last: decoding it first would turn a literal
        // "&amp;lt;" into "<".
        let entities = [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&amp;", "&")]
        for (entity, character) in entities {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        // A `<br/>` followed by the newline that was already there shouldn't
        // leave a gap bigger than a paragraph break.
        text = text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
