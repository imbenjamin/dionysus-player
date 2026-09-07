import Foundation

/// Login details persisted so the app can automatically sign the user back
/// in on next launch. Stored in the Keychain, never in `UserDefaults`.
struct StoredCredentials: Codable, Equatable {
    var username: String
    /// Optional: Jellyfin allows accounts with no password.
    var password: String?
    var accessToken: String?
    var userID: String?
}
