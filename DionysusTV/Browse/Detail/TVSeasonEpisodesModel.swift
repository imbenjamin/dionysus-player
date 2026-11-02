import Foundation
import Observation

/// One show's episodes, a season at a time, for the show page's rail. iOS
/// keeps this inside `SeasonEpisodeList`, a view; on the Apple TV the shell
/// tears pages down and rebuilds them, so it lives in a model the page owns.
@MainActor
@Observable
final class TVSeasonEpisodesModel {
    private(set) var episodes: [String: [MediaItem]] = [:]
    private(set) var failedSeasons: Set<String> = []
    /// Favorite and watched writes that succeeded, laid over every list until
    /// the server reports them: Jellyfin commits userData late, and a refetch
    /// in between would otherwise undo the change on screen.
    private var favoriteOverrides: [String: Bool] = [:]
    private var watchedOverrides: [String: Bool] = [:]

    private let client: JellyfinAPIClient
    private let userID: String
    private let seriesID: String

    init(client: JellyfinAPIClient, userID: String, seriesID: String) {
        self.client = client
        self.userID = userID
        self.seriesID = seriesID
    }

    /// Drops every season but `seasonIDs`, so the rest are fetched again
    /// when next on show: after a deletion any of them may be stale.
    func retain(_ seasonIDs: Set<String>) {
        episodes = episodes.filter { seasonIDs.contains($0.key) }
        failedSeasons.formIntersection(seasonIDs)
    }

    /// Shows a successful favorite or watched write on the episode wherever
    /// it's listed.
    func applyStatus(itemID: String, favorite: Bool? = nil, watched: Bool? = nil) {
        if let favorite { favoriteOverrides[itemID] = favorite }
        if let watched { watchedOverrides[itemID] = watched }
        episodes = episodes.mapValues { $0.map(applyingOverrides) }
    }

    /// Playback changes what was watched, so a write still unconfirmed
    /// stops speaking for the server once a session ends.
    func forgetStatusOverrides() {
        favoriteOverrides.removeAll()
        watchedOverrides.removeAll()
    }

    private func applyingOverrides(_ episode: MediaItem) -> MediaItem {
        let favorite = favoriteOverrides[episode.id].flatMap { $0 == episode.isFavorite ? nil : $0 }
        let watched = watchedOverrides[episode.id].flatMap { $0 == episode.isPlayed ? nil : $0 }
        return episode.withOptimisticFavoriteWatched(favorite: favorite, watched: watched)
    }

    /// Fetches a season once; `force` refetches it after playback or a
    /// watched change, keeping what's shown until the new list lands.
    func load(seasonID: String, force: Bool = false) async {
        guard force || episodes[seasonID] == nil else { return }
        do {
            let images = await client.makeImageURLBuilder()
            // With media sources: the show page reads its format badges
            // from the episode Play starts.
            let result = try await client.episodes(seriesID: seriesID, seasonID: seasonID, userID: userID, fields: JellyfinAPIClient.detailFields)
            let fetched = result.items.map { MediaItem(dto: $0, images: images) }
            for episode in fetched {
                if favoriteOverrides[episode.id] == episode.isFavorite { favoriteOverrides[episode.id] = nil }
                if watchedOverrides[episode.id] == episode.isPlayed { watchedOverrides[episode.id] = nil }
            }
            episodes[seasonID] = fetched.map(applyingOverrides)
            failedSeasons.remove(seasonID)
        } catch {
            // Cancelled isn't failed: the tabs follow focus, so passing a
            // season on the way to another cancels its fetch, and coming back
            // said it couldn't load until the refetch landed (M3 review).
            guard !Task.isCancelled else { return }
            if episodes[seasonID] == nil { failedSeasons.insert(seasonID) }
        }
    }
}
