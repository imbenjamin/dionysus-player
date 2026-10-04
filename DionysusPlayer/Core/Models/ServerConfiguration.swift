import Foundation

/// A configured Jellyfin server, as entered during first-run setup.
struct ServerConfiguration: Codable, Equatable, Identifiable {
    var id: String { baseURL.absoluteString }

    /// Seeded from the host, replaced with the server's reported name once a
    /// connection test succeeds.
    var name: String
    var baseURL: URL

    /// Parses a user-entered address: a bare host, a host and port, or a full
    /// URL. `preferHTTPS` decides the scheme only when the address doesn't
    /// specify one. Callers can use `explicitScheme(in:)` to keep a "use HTTPS"
    /// toggle from silently disagreeing with what gets used.
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

    /// The scheme explicitly present in a typed address, lowercased: the same
    /// check `parse(rawAddress:preferHTTPS:)` uses to decide whether
    /// `preferHTTPS` applies. Exposed so a "use HTTPS" toggle stays truthful —
    /// otherwise pasting a full `http://…` URL silently overrides an already-on
    /// toggle with no visible sign why.
    static func explicitScheme(in rawAddress: String) -> String? {
        let trimmed = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let schemeRange = trimmed.range(of: "://") else { return nil }
        return trimmed[..<schemeRange.lowerBound].lowercased()
    }

    /// Corrects `baseURL`'s scheme to where a connection test actually landed.
    /// `URLSession` follows an HTTP-to-HTTPS redirect transparently, so a `GET`
    /// ping over the wrong scheme still succeeds while `baseURL` records the
    /// wrong one. Uncorrected, every later request — sign-in's `POST` included —
    /// goes out on that scheme, which isn't redirect-safe the way the ping is,
    /// and fails with no indication why.
    ///
    /// Only the scheme changes. Returns `self` when `landedURL` has no scheme or
    /// already matches.
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
