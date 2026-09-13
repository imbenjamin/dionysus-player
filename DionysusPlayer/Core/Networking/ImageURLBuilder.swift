import Foundation

/// A value snapshot of what's needed to build Jellyfin image URLs, so views can
/// compute them synchronously inside a `body` without hopping back to the
/// `JellyfinAPIClient` actor per thumbnail.
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

    /// One chapter's still frame: `url(itemID:...)`'s route and query plus a
    /// trailing index segment, since Jellyfin addresses a chapter image by its
    /// 0-based position — a `ChapterInfoDto` has no id.
    ///
    /// `tag` is non-optional here: a chapter with no `imageTag` has no image at
    /// all, unlike an episode's tagless but still served Primary image.
    func chapterImageURL(itemID: String, chapterIndex: Int, tag: String, maxWidth: Int? = nil) -> URL? {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("Items/\(itemID)/Images/Chapter/\(chapterIndex)"),
            resolvingAgainstBaseURL: false
        ) else { return nil }

        var query: [URLQueryItem] = [.init(name: "tag", value: tag)]
        if let maxWidth { query.append(.init(name: "maxWidth", value: String(maxWidth))) }
        if let accessToken { query.append(.init(name: "ApiKey", value: accessToken)) }
        components.queryItems = query
        return components.url
    }

    /// A user's profile picture, from `Users/{id}/Images/{type}` rather than the
    /// item-image route. `tag` should be `UserDto.primaryImageTag`.
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

    /// One trickplay tile-sheet JPEG. The route takes no `MediaSourceId` segment:
    /// `width` and `sheetIndex` are its only variables. `TrickplayMath` turns a
    /// scrub position into which sheet and tile.
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
