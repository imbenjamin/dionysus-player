import Foundation

/// The Top Shelf extension's fetch (M6), in the app target as well so it's
/// unit-tested. It uses the session the app mirrored (`TopShelfSession`),
/// presenting the app's own device id, and never signs in: with no usable
/// session, the shelf falls back to the static Top Shelf image.
enum TopShelfLoader {
    /// tvOS gives the extension little time; a slow server shows the static
    /// image rather than holding the shelf.
    static let timeout: TimeInterval = 8

    static func load(session: TopShelfSession?, urlSession: URLSession) async -> [TopShelfEntry] {
        guard let session else { return [] }
        // The app's identity, so the token is presented with the device id
        // it was issued to.
        DeviceIdentity.adopt(deviceID: session.deviceID, deviceName: session.deviceName)
        let userID = session.userID
        let client = JellyfinAPIClient(baseURL: session.serverURL, accessToken: session.accessToken, session: urlSession)
        do {
            async let resume = client.resumeItems(
                userID: userID, excludeItemTypes: JellyfinAPIClient.audioItemTypeExclusions, fields: JellyfinAPIClient.topShelfFields)
            async let nextUp = client.nextUp(userID: userID, limit: TopShelfContentBuilder.totalLimit, fields: JellyfinAPIClient.topShelfFields)
            async let latest = recentlyAdded(client: client, userID: userID)
            return try await TopShelfContentBuilder.entries(
                resume: resume.items, nextUp: nextUp.items, latest: latest,
                images: client.makeImageURLBuilder(), serverID: session.serverID
            )
        } catch {
            return []
        }
    }

    /// Home's Recently Added (Benjamin, 2026-10-16): the first Movies
    /// library's newest, then the first TV Shows library's, each asked for by
    /// its id. Unscoped, `/Items/Latest` draws on every library (music and
    /// books crowd out video) and groups by whichever library comes first.
    private static func recentlyAdded(client: JellyfinAPIClient, userID: String) async throws -> [BaseItemDto] {
        let libraries = try await client.userViews(userID: userID).items
        func latest(collectionType: String) async throws -> [BaseItemDto] {
            guard let library = libraries.first(where: { $0.collectionType == collectionType }) else { return [] }
            return try await client.latestItems(
                userID: userID, parentID: library.id, limit: TopShelfContentBuilder.totalLimit, fields: JellyfinAPIClient.topShelfFields)
        }
        async let movies = latest(collectionType: JellyfinCollectionType.movies)
        async let shows = latest(collectionType: JellyfinCollectionType.tvShows)
        return try await movies + shows
    }

    /// A session for the extension, with `timeout` on every request.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        return URLSession(configuration: configuration)
    }
}
