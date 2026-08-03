import Foundation
import Observation

@MainActor
@Observable
final class AssetDetailViewModel {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private(set) var item: MediaItem?
    private(set) var seasons: [MediaItem] = []
    private(set) var similar: [MediaItem] = []
    private(set) var collections: [MediaItem] = []
    private(set) var loadState: LoadState = .idle

    let itemID: String
    private let client: JellyfinAPIClient
    private let userID: String

    init(client: JellyfinAPIClient, userID: String, itemID: String) {
        self.client = client
        self.userID = userID
        self.itemID = itemID
    }

    func loadIfNeeded() async {
        guard item == nil else { return }
        await load()
    }

    func load() async {
        loadState = .loading
        do {
            let images = await client.makeImageURLBuilder()
            let dto = try await client.item(userID: userID, itemID: itemID)
            item = MediaItem(dto: dto, images: images)

            async let similarResult = client.similarItems(itemID: itemID, userID: userID)
            async let collectionsResult = client.collectionsContaining(itemID: itemID, userID: userID)

            if dto.type == .series {
                let seasonsResult = try await client.seasons(seriesID: itemID, userID: userID)
                seasons = seasonsResult.items.map { MediaItem(dto: $0, images: images) }
            }

            similar = try await similarResult.items.map { MediaItem(dto: $0, images: images) }
            collections = try await collectionsResult.map { MediaItem(dto: $0, images: images) }

            loadState = .loaded
        } catch {
            loadState = .failed((error as? LocalizedError)?.errorDescription ?? "Couldn't load this title.")
        }
    }

    /// For a Series' "Play" button: resumes an in-progress episode, else
    /// the next unwatched one, else the first episode of the first season.
    func resolveSeriesPlaybackItemID() async -> String? {
        guard let item, item.kind == .series else { return nil }

        if let next = try? await client.nextUp(userID: userID, seriesID: item.id).items.first {
            return next.id
        }

        guard let firstSeason = seasons.first else { return nil }
        return try? await client.episodes(seriesID: item.id, seasonID: firstSeason.id, userID: userID).items.first?.id
    }
}
