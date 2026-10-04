import Foundation

/// Login details persisted so the app can automatically sign the user back
/// in on next launch. Stored in the Keychain, never in `UserDefaults`.
struct StoredCredentials: Codable, Equatable {
    /// How the session was obtained, which decides how launch restores it.
    /// A password session signs in again; a Quick Connect one has no
    /// password, so it validates its stored token instead.
    ///
    /// Explicit rather than inferred from `password == nil`: passwordless
    /// accounts sign in by password too, storing `""`, and one nil check in
    /// the wrong place would send them down the token path.
    enum AuthMethod: String, Codable {
        case password
        case quickConnect
    }

    var username: String
    /// Optional: Jellyfin allows accounts with no password. Always `nil` for
    /// `.quickConnect`.
    var password: String?
    var accessToken: String?
    var userID: String?
    var authMethod: AuthMethod = .password

    init(
        username: String,
        password: String?,
        accessToken: String?,
        userID: String?,
        authMethod: AuthMethod = .password
    ) {
        self.username = username
        self.password = password
        self.accessToken = accessToken
        self.userID = userID
        self.authMethod = authMethod
    }

    /// Keychain entries written before Quick Connect existed have no
    /// `authMethod`, and every one of them was a password sign-in.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        username = try container.decode(String.self, forKey: .username)
        password = try container.decodeIfPresent(String.self, forKey: .password)
        accessToken = try container.decodeIfPresent(String.self, forKey: .accessToken)
        userID = try container.decodeIfPresent(String.self, forKey: .userID)
        authMethod = try container.decodeIfPresent(AuthMethod.self, forKey: .authMethod) ?? .password
    }
}
