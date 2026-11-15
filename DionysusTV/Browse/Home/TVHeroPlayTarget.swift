import Foundation

/// What the hero's Play starts. A movie or an episode plays itself; a series
/// id doesn't play, so its next episode is resolved the way the show page
/// resolves it (`AssetDetailViewModel.resolveShowPlaybackEpisode`): NextUp,
/// which returns an in-progress episode or the next unwatched one, falling
/// back to the first episode for a show never started.
///
/// The item, not just its id: whether it has a resume point decides whether
/// the version question (#289) is asked (`MediaVersionResolver`).
enum TVHeroPlayTarget {
    static func resolve(_ item: MediaItem, client: JellyfinAPIClient, userID: String) async -> MediaItem? {
        guard item.kind == .series else { return item }
        let episode: BaseItemDto?
        if let next = try? await client.nextUp(userID: userID, seriesID: item.id).items.first {
            episode = next
        } else {
            episode = try? await client.episodes(seriesID: item.id, userID: userID).items.first
        }
        guard let episode else { return nil }
        return MediaItem(dto: episode, images: await client.makeImageURLBuilder())
    }
}
