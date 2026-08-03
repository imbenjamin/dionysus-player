import Foundation

enum JellyfinAPIError: Error, LocalizedError {
    case invalidServerAddress
    case invalidResponse
    case http(status: Int, message: String?)
    case decoding(Error)
    case notAuthenticated

    var errorDescription: String? {
        switch self {
        case .invalidServerAddress:
            "That doesn't look like a valid server address."
        case .invalidResponse:
            "The server sent an unexpected response."
        case .http(let status, let message):
            "Server returned \(status)\(message.map { ": \($0)" } ?? "")."
        case .decoding:
            "Couldn't understand the server's response."
        case .notAuthenticated:
            "You need to sign in again."
        }
    }
}
