import Foundation

/// A plain-value snapshot of what's needed to build Jellyfin image URLs, so
/// views can compute them synchronously (e.g. inside a SwiftUI `body`)
/// without hopping back to the `JellyfinAPIClient` actor for every
/// poster/thumbnail.
struct ImageURLBuilder: Equatable {
    var baseURL: URL
    var accessToken: String?

    func url(itemID: String, imageType: String = "Primary", tag: String? = nil, maxWidth: Int? = nil) -> URL? {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("Items/\(itemID)/Images/\(imageType)"),
            resolvingAgainstBaseURL: false
        ) else { return nil }

        var query: [URLQueryItem] = []
        if let tag { query.append(.init(name: "tag", value: tag)) }
        if let maxWidth { query.append(.init(name: "maxWidth", value: String(maxWidth))) }
        if let accessToken { query.append(.init(name: "ApiKey", value: accessToken)) }
        components.queryItems = query.isEmpty ? nil : query
        return components.url
    }
}
