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

    /// URL for a user's profile picture. Uses Jellyfin's `Users/{id}/Images/{type}`
    /// endpoint (distinct from item images); `tag` should be `UserDto.primaryImageTag`.
    func userImageURL(userID: String, imageType: String = "Primary", tag: String? = nil, maxWidth: Int? = nil) -> URL? {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("Users/\(userID)/Images/\(imageType)"),
            resolvingAgainstBaseURL: false
        ) else { return nil }

        var query: [URLQueryItem] = []
        if let tag { query.append(.init(name: "tag", value: tag)) }
        if let maxWidth { query.append(.init(name: "maxWidth", value: String(maxWidth))) }
        if let accessToken { query.append(.init(name: "ApiKey", value: accessToken)) }
        components.queryItems = query.isEmpty ? nil : query
        return components.url
    }

    /// URL for one Jellyfin trickplay tile-sheet JPEG. Confirmed live: the
    /// route takes no `MediaSourceId` path segment — unlike `url(itemID:...)`'s
    /// `/Items/{id}/Images/...` shape, `width` and `sheetIndex` are the only
    /// variables. See `TrickplayThumbnailProvider` for the math that turns
    /// a scrub position into which sheet to fetch and which tile to crop.
    func trickplayTileURL(itemID: String, width: Int, sheetIndex: Int) -> URL? {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("Videos/\(itemID)/Trickplay/\(width)/\(sheetIndex).jpg"),
            resolvingAgainstBaseURL: false
        ) else { return nil }

        var query: [URLQueryItem] = []
        if let accessToken { query.append(.init(name: "ApiKey", value: accessToken)) }
        components.queryItems = query.isEmpty ? nil : query
        return components.url
    }
}
