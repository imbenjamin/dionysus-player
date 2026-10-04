import Foundation

/// What the hero's Play starts. A movie or an episode plays itself; a series
/// id doesn't play, so its next episode is resolved the way the show page
/// resolves it (`AssetDetailViewModel.resolveShowPlaybackEpisode`): NextUp,
/// which returns an in-progress episode or the next unwatched one, falling
/// back to the first episode for a show never started.
enum TVHeroPlayTarget {
    static func resolve(_ item: MediaItem, client: JellyfinAPIClient, userID: String) async -> String? {
        guard item.kind == .series else { return item.id }
        if let next = try? await client.nextUp(userID: userID, seriesID: item.id).items.first {
            return next.id
        }
        return try? await client.episodes(seriesID: item.id, userID: userID).items.first?.id
    }
}
