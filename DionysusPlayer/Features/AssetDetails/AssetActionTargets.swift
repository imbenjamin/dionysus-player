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
    /// Every entity the page could offer to delete, most specific last.
    ///
    /// Mirrors `FavoriteWatchedShowScope` with one difference: the episode is
    /// offered only when the page is genuinely showing an episode, never for
    /// `AssetDetailViewModel.showPlaybackEpisode`. Getting favorite/watched
    /// wrong costs a toggle; offering to delete an episode the user never
    /// selected destroys a file.
    let deletable: [MediaItem]

    /// Every entity the page could offer to add to a playlist, most specific
    /// last.
    ///
    /// The same shape as `deletable`, including its restriction to genuine
    /// episode content. That restriction is destructive-only in origin, but
    /// both actions sit in one menu and must agree on what "this episode"
    /// means.
    ///
    /// No permission filter, unlike `deletable`: every target is addable
    /// somewhere, since a user with no editable playlist can create one
    /// (`POST /Playlists` has no permission gate).
    let addable: [MediaItem]

    /// - Parameters:
    ///   - item: what the page shows (a movie, the series, or an episode).
    ///   - seriesItem: the show, on a show's page; `nil` for standalone content.
    ///   - selectedSeasonID: the season on show (iOS's picker, the Apple TV's
    ///     season tabs).
    ///   - canDeleteSeason: `AssetDetailViewModel.canDelete(season:)`: a season
    ///     with no folder of its own is never deletable as a unit, and is
    ///     offered when its episodes are.
    init(
        item: MediaItem?, seriesItem: MediaItem?, seasons: [MediaItem],
        selectedSeasonID: String?, canDeleteSeason: (MediaItem) -> Bool
    ) {
        guard let item else {
            deletable = []
            addable = []
            return
        }
        guard let show = seriesItem else {
            // Movie or other standalone content: one possible target.
            addable = [item]
            deletable = [item].filter(\.canDelete)
            return
        }
        let season = seasons.first { $0.id == selectedSeasonID }
        let episode = item.kind == .episode ? item : nil
        let all = [show, season, episode].compactMap { $0 }
        addable = all
        deletable = all.filter { target in
            target.kind == .season ? canDeleteSeason(target) : target.canDelete
        }
    }

    @MainActor
    init(viewModel: AssetDetailViewModel, selectedSeasonID: String?) {
        self.init(
            item: viewModel.item, seriesItem: viewModel.seriesItem, seasons: viewModel.seasons,
            selectedSeasonID: selectedSeasonID, canDeleteSeason: viewModel.canDelete(season:)
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
}
