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
    /// `preferHTTPS` decides which one is assumed — when one *is* present,
    /// it always wins over `preferHTTPS` (see `explicitScheme(in:)`, which
    /// callers can use to keep a "use HTTPS" toggle in sync with that so it
    /// never silently disagrees with what actually gets used).
    static func parse(rawAddress: String, preferHTTPS: Bool) -> ServerConfiguration? {
        let trimmed = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let urlString = explicitScheme(in: trimmed) != nil
            ? trimmed
            : "\(preferHTTPS ? "https" : "http")://\(trimmed)"

        guard let url = URL(string: urlString), let host = url.host, !host.isEmpty else {
            return nil
        }

        return ServerConfiguration(name: host, baseURL: url)
    }

    /// The scheme (`"http"`/`"https"`, lowercased) explicitly present in a
    /// user-typed address, if any — the same "does this already specify a
    /// scheme" check `parse(rawAddress:preferHTTPS:)` uses to decide whether
    /// `preferHTTPS` even applies. Exposed so a "use HTTPS" toggle bound
    /// elsewhere (`ServerSetupViewModel`) can be kept truthful: without
    /// this, pasting or retyping a full `http://…` URL over a previous
    /// address silently overrides an already-on toggle with no visible
    /// sign why — confirmed live, both in Simulator and on a physical
    /// device.
    static func explicitScheme(in rawAddress: String) -> String? {
        let trimmed = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let schemeRange = trimmed.range(of: "://") else { return nil }
        return trimmed[..<schemeRange.lowerBound].lowercased()
    }

    /// Corrects `baseURL`'s scheme to match where a connection test actually
    /// landed, if different — `URLSession` follows a server's HTTP→HTTPS
    /// redirect transparently, so a `GET` ping over the *wrong* scheme can
    /// still come back successful (confirmed live: a public Jellyfin server
    /// 302-redirects a plain-HTTP request to HTTPS) even though `baseURL`
    /// itself still records the wrong one. Left uncorrected, every later
    /// request — sign-in's `POST` included — goes out on that wrong scheme,
    /// which isn't itself redirect-safe the way a `GET` ping is, and fails
    /// with no indication why. Only the scheme changes; host/port/path stay
    /// exactly what the user configured. Returns `self` unchanged if
    /// `landedURL` has no scheme or it already matches.
    func correctingScheme(usingLandedURL landedURL: URL?) -> ServerConfiguration {
        guard let landedScheme = landedURL?.scheme,
              landedScheme.caseInsensitiveCompare(baseURL.scheme ?? "") != .orderedSame,
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        else { return self }
        components.scheme = landedScheme
        guard let correctedURL = components.url else { return self }
        var corrected = self
        corrected.baseURL = correctedURL
        return corrected
    }
}
