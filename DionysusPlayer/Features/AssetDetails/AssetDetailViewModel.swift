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

    /// `preloadedItem` — see `AppRoute.assetDetail`'s doc comment — seeds
    /// `item` immediately so the page has something to render (and a zoom
    /// transition something to land on) before `load()`'s network round
    /// trip resolves. It's necessarily partial (fetched via the rail's
    /// lighter `Fields` list, missing `MediaSources`/`People`), so `load()`
    /// still runs regardless and replaces it with the full item once ready.
    init(client: JellyfinAPIClient, userID: String, itemID: String, preloadedItem: MediaItem? = nil) {
        self.client = client
        self.userID = userID
        self.itemID = itemID
        self.item = preloadedItem
    }

    /// Guards on `loadState`, not `item` — a preloaded item already makes
    /// `item` non-nil before `load()` has ever run, which would otherwise
    /// make this look like a no-op-needed reload and skip fetching the full
    /// item (cast, technical details, similar/collections rails) entirely.
    func loadIfNeeded() async {
        guard loadState == .idle else { return }
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

    /// Re-fetches just the main item's DTO so the Play/Resume button and its
    /// progress bar reflect the latest server-side watch state (e.g. after
    /// returning from the player). Skips the sibling rails/seasons — they
    /// haven't meaningfully changed during one playback session.
    ///
    /// `PlayerViewModel.stop()` awaits the `/Sessions/Playing/Stopped` POST,
    /// but Jellyfin commits the userData write asynchronously after that
    /// response returns — and the commit latency varies. Rather than gamble
    /// on a fixed delay, this polls the item endpoint on a short schedule
    /// until the returned userData actually differs from what we had (which
    /// means the server has caught up), or we hit the last attempt.
    func refreshItem() async {
        let previousTicks = item?.dto.userData?.playbackPositionTicks
        let previousPercentage = item?.dto.userData?.playedPercentage
        let previouslyPlayed = item?.dto.userData?.played
        let images = await client.makeImageURLBuilder()

        for delay in [0.25, 0.5, 1.0, 1.5] as [Double] {
            try? await Task.sleep(for: .seconds(delay))
            guard let dto = try? await client.item(userID: userID, itemID: itemID) else { continue }
            item = MediaItem(dto: dto, images: images)
            if dto.userData?.playbackPositionTicks != previousTicks
                || dto.userData?.playedPercentage != previousPercentage
                || dto.userData?.played != previouslyPlayed {
                return
            }
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
