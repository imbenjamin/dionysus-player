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

    /// The server has no such item: deleted, or never there. Jellyfin answers
    /// `GET /Users/{id}/Items/{id}` for a missing id with a 404.
    var isNotFound: Bool {
        if case .http(status: 404, message: _) = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .invalidServerAddress:
            String(localized: "That doesn't look like a valid server address.")
        case .invalidResponse:
            String(localized: "The server sent an unexpected response.")
        // The body is never shown: a server (or a proxy in front of it) can
        // answer an error with a whole HTML page, which read as raw markup.
        case .http(let status, _):
            String(localized: "Something went wrong (HTTP \(status)).")
        case .decoding:
            String(localized: "Couldn't understand the server's response.")
        case .notAuthenticated:
            String(localized: "You need to sign in again.")
        case .notPermitted:
            String(localized: "You don't have permission to do that on this server.")
        }
    }
}
