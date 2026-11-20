import Foundation

/// Offline Up Next (#274): the download to cue after `current`, decided from
/// the downloads alone. Only the **immediate** next episode, and only when it
/// is downloaded: a gap (E4 not downloaded) cues nothing rather than skipping
/// to E5 (Benjamin, 2026-11-20).
///
/// The following number in the same season (after a double episode's last)
/// always comes first. Only without one does the server's own answer,
/// recorded at download time (`DownloadedItem.hasNextEpisodeRecord`), decide:
/// that's how a season finale reaches the next season, which the device can't
/// otherwise tell from a season with episodes left undownloaded. The record is
/// the server as it was then, so on a show still airing it can be stale ("the
/// series ends here" before E4 aired); the same-season rule going first keeps
/// it from hiding E4 once that's downloaded, and a later episode of the same
/// season downloaded past a gap keeps a stale record from skipping the gap. A
/// download without a record (older than #274, or whose lookup failed) cues
/// within its season only. Specials (season 0) and unnumbered episodes never
/// cue and are never cued.
enum DownloadedNextEpisode {
    static func find(after current: DownloadedItem, among items: [DownloadedItem]) -> DownloadedItem? {
        guard current.kind == .episode, let seriesID = current.seriesID,
              let season = current.seasonNumber, season > 0,
              let episode = current.episodeNumber else { return nil }
        let last = current.episodeNumberEnd ?? episode

        let candidates = items.filter { candidate in
            guard candidate.itemID != current.itemID,
                  candidate.kind == .episode,
                  candidate.seriesID == seriesID,
                  candidate.userID == current.userID,
                  candidate.status == .completed,
                  !candidate.markedForDeletion,
                  let candidateSeason = candidate.seasonNumber, candidateSeason > 0,
                  candidate.episodeNumber != nil else { return false }
            return true
        }
        let sameSeason = candidates.filter { $0.seasonID == current.seasonID && $0.seasonNumber == season }

        if let next = sameSeason.first(where: { $0.episodeNumber == last + 1 }) { return next }
        // A later episode of this season is downloaded past a gap: the season
        // goes on, so a record pointing elsewhere is stale.
        if sameSeason.contains(where: { ($0.episodeNumber ?? 0) > last }) { return nil }

        guard current.hasNextEpisodeRecord == true,
              let nextSeason = current.nextEpisodeSeasonNumber,
              let nextEpisode = current.nextEpisodeNumber else { return nil }
        return candidates.first { $0.seasonNumber == nextSeason && $0.episodeNumber == nextEpisode }
    }
}
