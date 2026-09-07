import Foundation

enum JellyfinAPIError: Error, LocalizedError {
    case invalidServerAddress
    case invalidResponse
    case http(status: Int, message: String?)
    case decoding(Error)
    case notAuthenticated
    /// The credentials are fine, but this user isn't allowed to do this.
    ///
    /// Distinct from `.notAuthenticated` because Jellyfin answers *both*
    /// with HTTP 401 — `LibraryController.DeleteItem` returns
    /// `Unauthorized("Unauthorized access")` when the user lacks delete
    /// rights, which is indistinguishable at the status-code level from an
    /// expired token. Only requests that opt into a reduced reauth budget
    /// (see `JellyfinAPIClient.sendRaw`'s `maxReauthAttempts`) can produce
    /// this: without it, a permission failure would be retried against the
    /// full backoff schedule and finally reported as `.notAuthenticated`,
    /// which is documented as sending the user back to the login screen —
    /// i.e. pressing Delete without permission would log you out.
    case notPermitted

    var errorDescription: String? {
        switch self {
        case .invalidServerAddress:
            String(localized: "That doesn't look like a valid server address.")
        case .invalidResponse:
            String(localized: "The server sent an unexpected response.")
        case .http(let status, let message):
            String(localized: "Server returned \(status)\(message.map { ": \($0)" } ?? "").")
        case .decoding:
            String(localized: "Couldn't understand the server's response.")
        case .notAuthenticated:
            String(localized: "You need to sign in again.")
        case .notPermitted:
            String(localized: "You don't have permission to do that on this server.")
        }
    }
}
