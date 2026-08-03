import Foundation

/// A configured Jellyfin server, as entered during first-run setup.
struct ServerConfiguration: Codable, Equatable, Identifiable {
    var id: String { baseURL.absoluteString }

    /// Display name. Seeded from the host, replaced with the server's
    /// reported name once a connection test succeeds.
    var name: String
    var baseURL: URL

    /// Parses a user-entered address into a `ServerConfiguration`.
    ///
    /// Accepts a bare host (`192.168.1.50`), host and port
    /// (`192.168.1.50:8096`), or a fully-qualified URL
    /// (`https://jellyfin.example.com`). When no scheme is present,
    /// `preferHTTPS` decides which one is assumed.
    static func parse(rawAddress: String, preferHTTPS: Bool) -> ServerConfiguration? {
        let trimmed = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let urlString = trimmed.contains("://")
            ? trimmed
            : "\(preferHTTPS ? "https" : "http")://\(trimmed)"

        guard let url = URL(string: urlString), let host = url.host, !host.isEmpty else {
            return nil
        }

        return ServerConfiguration(name: host, baseURL: url)
    }
}
