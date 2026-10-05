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

    private let client: JellyfinAPIClient
    private let userID: String
    private let seriesID: String

    init(client: JellyfinAPIClient, userID: String, seriesID: String) {
        self.client = client
        self.userID = userID
        self.seriesID = seriesID
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
            episodes[seasonID] = result.items.map { MediaItem(dto: $0, images: images) }
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
