import Foundation

/// What a detail page's More Actions offer: the entities it may add to a
/// playlist or delete, with the copy that names them. Shared by iOS's
/// `AssetActionsButton` and the Apple TV's `TVMoreActionsButton`, so both
/// offer the same targets in the same words; UI-free, and compiled on tvOS
/// (`project.yml`).
///
/// Scoped to movies, episodes, seasons and shows; box sets and playlists
/// don't offer these (see `AssetActionsButton`).
struct AssetActionTargets: Equatable {
    /// Every entity the page could offer to delete, most specific last: the
    /// show, the season on show, and the episode Play starts (the page's own
    /// on an episode, `AssetDetailViewModel.showPlaybackEpisode` on the
    /// series).
    ///
    /// The series' episode used to be left out, since deleting an episode the
    /// user never chose destroys a file. It's offered now (Benjamin,
    /// 2026-10-26): Play names it on the page, the row names it by number
    /// and title, and the confirmation names it again.
    let deletable: [MediaItem]

    /// Every entity the page could offer to add to a playlist, most specific
    /// last: the same targets as `deletable`, so both actions in the one menu
    /// agree on what "this episode" means.
    ///
    /// No permission filter, unlike `deletable`: every target is addable
    /// somewhere, since a user with no editable playlist can create one
    /// (`POST /Playlists` has no permission gate).
    let addable: [MediaItem]

    /// What Delete offers, in menu order: `deletable` as `.item`s, then All
    /// Watched (#437) last, which the menus set apart below a divider
    /// (Benjamin, 2026-11-19): a batch of episodes, not one entity.
    let deleteRequests: [AssetDeleteRequest]

    /// - Parameters:
    ///   - item: what the page shows (a movie, the series, or an episode).
    ///   - seriesItem: the show, on a show's page; `nil` for standalone content.
    ///   - selectedSeasonID: the season on show (iOS's picker, the Apple TV's
    ///     season tabs).
    ///   - playbackEpisode: the episode Play starts on the series
    ///     (`AssetDetailViewModel.showPlaybackEpisode`); ignored when `item`
    ///     is an episode, which is then Play's.
    ///   - watchedEpisodes: `AssetDetailViewModel.watchedEpisodes`, the show's
    ///     watched episodes All Watched would delete; `nil` offers no row.
    ///     No default: a caller that left it out dropped the row silently.
    ///   - canDeleteSeason: `AssetDetailViewModel.canDelete(season:)`: a season
    ///     with no folder of its own is never deletable as a unit, and is
    ///     offered when its episodes are.
    init(
        item: MediaItem?, seriesItem: MediaItem?, seasons: [MediaItem],
        selectedSeasonID: String?, playbackEpisode: MediaItem?,
        watchedEpisodes: WatchedEpisodesDeletion?,
        canDeleteSeason: (MediaItem) -> Bool
    ) {
        guard let item else {
            deletable = []
            addable = []
            deleteRequests = []
            return
        }
        guard let show = seriesItem else {
            // Movie or other standalone content: one possible target.
            addable = [item]
            deletable = [item].filter(\.canDelete)
            deleteRequests = deletable.map(AssetDeleteRequest.item)
            return
        }
        let season = seasons.first { $0.id == selectedSeasonID }
        let episode = item.kind == .episode ? item : playbackEpisode
        let all = [show, season, episode].compactMap { $0 }
        addable = all
        let deletable = all.filter { target in
            target.kind == .season ? canDeleteSeason(target) : target.canDelete
        }
        self.deletable = deletable
        deleteRequests = deletable.map(AssetDeleteRequest.item)
            + [watchedEpisodes].compactMap { $0.map(AssetDeleteRequest.watchedEpisodes) }
    }

    @MainActor
    init(viewModel: AssetDetailViewModel, selectedSeasonID: String?) {
        self.init(
            item: viewModel.item, seriesItem: viewModel.seriesItem, seasons: viewModel.seasons,
            selectedSeasonID: selectedSeasonID, playbackEpisode: viewModel.showPlaybackEpisode,
            watchedEpisodes: viewModel.watchedEpisodes,
            canDeleteSeason: viewModel.canDelete(season:)
        )
    }

    // MARK: - Copy

    /// The delete action's name: a confirmation's title, and a lone target's
    /// row.
    static func deleteActionLabel(for target: MediaItem) -> String {
        switch target.kind {
        case .series: return String(localized: "Delete Show")
        case .season: return String(localized: "Delete Season")
        case .episode: return String(localized: "Delete Episode")
        default: return String(localized: "Delete")
        }
    }

    /// A row among several targets names the specific entity, not just its
    /// type: the rows exist to tell similar targets apart.
    static func rowLabel(for target: MediaItem) -> String {
        target.kind == .episode ? target.numberedEpisodeName : target.name
    }

    /// Spells out that the file leaves the server and isn't recoverable: this
    /// deletes from the filesystem, not just the library (see
    /// `JellyfinAPIClient.deleteItem`).
    ///
    /// The show and season variants are separate literals with the noun written
    /// into each rather than one string interpolating it. The English is
    /// identical, but a substituted bare noun can't be translated into languages
    /// where the surrounding words inflect for it.
    static func deleteConfirmationMessage(for target: MediaItem) -> String {
        switch target.kind {
        case .series:
            if let count = target.episodeCount, count > 0 {
                return String(localized: "Deleting this show will delete all \(count) episodes from the Jellyfin server. This cannot be undone.")
            }
            return String(localized: "Deleting this show will delete all of its episodes from the Jellyfin server. This cannot be undone.")
        case .season:
            if let count = target.episodeCount, count > 0 {
                return String(localized: "Deleting this season will delete all \(count) episodes from the Jellyfin server. This cannot be undone.")
            }
            return String(localized: "Deleting this season will delete all of its episodes from the Jellyfin server. This cannot be undone.")
        default:
            return String(localized: "Deleting \"\(target.name)\" will remove it from the Jellyfin server. This cannot be undone.")
        }
    }

    /// All Watched's confirmation (Benjamin, 2026-11-19): how many go, that
    /// they go for every user (Watched is this user's, the file everyone's),
    /// and how many stay. Three sentences, each counted one a plural in the
    /// String Catalog.
    ///
    /// With none left it doesn't promise the show goes (#491; Benjamin,
    /// 2026-11-20): missing episodes, or a folder Jellyfin keeps, can leave it
    /// listed. The page pops if it does go.
    static func deleteWatchedConfirmationMessage(for deletion: WatchedEpisodesDeletion) -> String {
        let count = deletion.watched.count
        let remaining = deletion.remainingCount
        let show = deletion.show.name
        let deleted = String(localized: "\(count) episodes that are watched will be deleted for all users.")
        let remain = remaining > 0
            ? String(localized: "\(remaining) episodes will remain for \(show).")
            : String(localized: "No episodes will remain for \(show).")
        return [deleted, remain, String(localized: "This cannot be undone.")].joined(separator: " ")
    }
}

/// A show's watched episodes, as All Watched would delete them (#437):
/// the snapshot the menu offered and the confirmation counted, so what's
/// deleted is exactly what the user was told.
struct WatchedEpisodesDeletion: Equatable {
    let show: MediaItem
    /// Watched (`UserData.Played`) episodes with a file, in the server's order.
    let watched: [MediaItem]
    /// Every episode of the show with a file, watched or not.
    let totalCount: Int

    var remainingCount: Int { totalCount - watched.count }
}

/// One row of the Delete menu: a single entity, or a show's watched
/// episodes. What both platforms' menus and confirmations work from.
enum AssetDeleteRequest: Identifiable, Equatable {
    case item(MediaItem)
    case watchedEpisodes(WatchedEpisodesDeletion)

    var id: String {
        switch self {
        case .item(let target): target.id
        case .watchedEpisodes(let deletion): "watched.\(deletion.show.id)"
        }
    }

    /// The row's name among several.
    var rowLabel: String {
        switch self {
        case .item(let target): AssetActionTargets.rowLabel(for: target)
        case .watchedEpisodes: String(localized: "All Watched")
        }
    }

    /// The confirmation's title, and a lone row's name.
    var actionLabel: String {
        switch self {
        case .item(let target): AssetActionTargets.deleteActionLabel(for: target)
        case .watchedEpisodes: String(localized: "Delete Watched Episodes")
        }
    }

    var confirmationMessage: String {
        switch self {
        case .item(let target): AssetActionTargets.deleteConfirmationMessage(for: target)
        case .watchedEpisodes(let deletion): AssetActionTargets.deleteWatchedConfirmationMessage(for: deletion)
        }
    }

    /// The items this deletes by id: the entity itself, or each watched
    /// episode. A season or show's own downloads are found by its id
    /// instead (`AssetActionsButton.downloadedItemIDs`).
    var affectedItemIDs: [String] {
        switch self {
        case .item(let target): [target.id]
        case .watchedEpisodes(let deletion): deletion.watched.map(\.id)
        }
    }
}
