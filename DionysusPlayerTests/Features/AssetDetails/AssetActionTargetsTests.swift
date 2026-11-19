import XCTest
@testable import Dionysus

/// What the detail pages' More Actions offer, shared by iOS's
/// `AssetActionsButton` and the Apple TV's `TVMoreActionsButton`.
final class AssetActionTargetsTests: XCTestCase {
    private let images = ImageURLBuilder(baseURL: URL(string: "https://example.com")!, accessToken: "tok")

    private func item(
        _ id: String, _ type: BaseItemKind, name: String? = nil, canDelete: Bool = true,
        episodeCount: Int? = nil, season: Int? = nil, episode: Int? = nil
    ) -> MediaItem {
        var dto = BaseItemDto(id: id, name: name ?? id, type: type)
        dto.canDelete = canDelete
        dto.recursiveItemCount = episodeCount
        dto.parentIndexNumber = season
        dto.indexNumber = episode
        return MediaItem(dto: dto, images: images)
    }

    private lazy var show = item("show", .series, name: "Breaking Bad")
    private lazy var season1 = item("s1", .season, name: "Season 1")
    private lazy var season2 = item("s2", .season, name: "Season 2")

    func test_movie_offersItselfForBoth() {
        let movie = item("movie", .movie)
        let targets = AssetActionTargets(item: movie, seriesItem: nil, seasons: [], selectedSeasonID: nil, playbackEpisode: nil, watchedEpisodes: nil) { _ in false }
        XCTAssertEqual(targets.addable.map(\.id), ["movie"])
        XCTAssertEqual(targets.deletable.map(\.id), ["movie"])
    }

    func test_movieWithoutCanDelete_isAddableButNotDeletable() {
        let movie = item("movie", .movie, canDelete: false)
        let targets = AssetActionTargets(item: movie, seriesItem: nil, seasons: [], selectedSeasonID: nil, playbackEpisode: nil, watchedEpisodes: nil) { _ in false }
        XCTAssertEqual(targets.addable.map(\.id), ["movie"])
        XCTAssertTrue(targets.deletable.isEmpty)
    }

    /// The episode Play starts is offered too (Benjamin, 2026-10-26): the
    /// page names it on its Play button, so it's the episode "this" means.
    func test_seriesPage_offersShowSelectedSeasonAndPlaybackEpisode() {
        let next = item("e3", .episode, season: 1, episode: 3)
        let targets = AssetActionTargets(
            item: show, seriesItem: show, seasons: [season1, season2], selectedSeasonID: "s2",
            playbackEpisode: next, watchedEpisodes: nil
        ) { $0.canDelete }
        XCTAssertEqual(targets.addable.map(\.id), ["show", "s2", "e3"])
        XCTAssertEqual(targets.deletable.map(\.id), ["show", "s2", "e3"])
    }

    func test_seriesPage_playbackEpisodeWithoutCanDelete_isAddableButNotDeletable() {
        let next = item("e3", .episode, canDelete: false, season: 1, episode: 3)
        let targets = AssetActionTargets(
            item: show, seriesItem: show, seasons: [season1], selectedSeasonID: "s1",
            playbackEpisode: next, watchedEpisodes: nil
        ) { $0.canDelete }
        XCTAssertEqual(targets.addable.map(\.id), ["show", "s1", "e3"])
        XCTAssertEqual(targets.deletable.map(\.id), ["show", "s1"])
    }

    func test_seriesPage_withNothingToPlay_offersShowAndSeason() {
        let targets = AssetActionTargets(
            item: show, seriesItem: show, seasons: [season1, season2], selectedSeasonID: "s2",
            playbackEpisode: nil, watchedEpisodes: nil
        ) { $0.canDelete }
        XCTAssertEqual(targets.addable.map(\.id), ["show", "s2"])
        XCTAssertEqual(targets.deletable.map(\.id), ["show", "s2"])
    }

    /// On an episode's page Play is that episode, whatever the show's own
    /// next one is.
    func test_episodePage_offersItsOwnEpisode_notThePlaybackEpisode() {
        let episode = item("e4", .episode, season: 2, episode: 4)
        let next = item("e3", .episode, season: 1, episode: 3)
        let targets = AssetActionTargets(
            item: episode, seriesItem: show, seasons: [season1, season2], selectedSeasonID: "s2",
            playbackEpisode: next, watchedEpisodes: nil
        ) { $0.canDelete }
        XCTAssertEqual(targets.addable.map(\.id), ["show", "s2", "e4"])
    }

    func test_episodePage_offersShowSeasonEpisode_inThatOrder() {
        let episode = item("e4", .episode, season: 2, episode: 4)
        let targets = AssetActionTargets(
            item: episode, seriesItem: show, seasons: [season1, season2], selectedSeasonID: "s2",
            playbackEpisode: nil, watchedEpisodes: nil
        ) { $0.canDelete }
        XCTAssertEqual(targets.addable.map(\.id), ["show", "s2", "e4"])
        XCTAssertEqual(targets.deletable.map(\.id), ["show", "s2", "e4"])
    }

    func test_folderlessSeason_offeredOnlyWhenEveryEpisodeIsDeletable() {
        let folderless = item("s1", .season, canDelete: false)
        let before = AssetActionTargets(
            item: show, seriesItem: show, seasons: [folderless], selectedSeasonID: "s1", playbackEpisode: nil, watchedEpisodes: nil
        ) { _ in false }
        XCTAssertEqual(before.deletable.map(\.id), ["show"])
        XCTAssertEqual(before.addable.map(\.id), ["show", "s1"], "Adding has no permission gate.")

        let after = AssetActionTargets(
            item: show, seriesItem: show, seasons: [folderless], selectedSeasonID: "s1", playbackEpisode: nil, watchedEpisodes: nil
        ) { _ in true }
        XCTAssertEqual(after.deletable.map(\.id), ["show", "s1"])
    }

    func test_copy() {
        XCTAssertEqual(AssetActionTargets.deleteActionLabel(for: show), "Delete Show")
        XCTAssertEqual(AssetActionTargets.deleteActionLabel(for: season1), "Delete Season")
        XCTAssertEqual(AssetActionTargets.deleteActionLabel(for: item("e", .episode)), "Delete Episode")
        XCTAssertEqual(AssetActionTargets.deleteActionLabel(for: item("m", .movie)), "Delete")

        XCTAssertEqual(AssetActionTargets.rowLabel(for: show), "Breaking Bad")
        XCTAssertEqual(AssetActionTargets.rowLabel(for: item("e", .episode, name: "Pilot", season: 1, episode: 1)), "S1:E1 \u{00B7} Pilot")

        let counted = item("s", .season, episodeCount: 6)
        XCTAssertTrue(AssetActionTargets.deleteConfirmationMessage(for: counted).contains("all 6 episodes"))
        XCTAssertTrue(AssetActionTargets.deleteConfirmationMessage(for: season1).contains("all of its episodes"))
    }

    // MARK: - All Watched (#437)

    private func watched(_ count: Int, of total: Int, showName: String = "House of Games") -> WatchedEpisodesDeletion {
        WatchedEpisodesDeletion(
            show: item("show", .series, name: showName),
            watched: (1...count).map { item("w\($0)", .episode) },
            totalCount: total
        )
    }

    private func targets(showCanDelete: Bool = true, watchedEpisodes: WatchedEpisodesDeletion?) -> AssetActionTargets {
        let series = item("show", .series, name: "Breaking Bad", canDelete: showCanDelete)
        let episode = item("ep", .episode, season: 1, episode: 1)
        return AssetActionTargets(
            item: episode, seriesItem: series, seasons: [season1], selectedSeasonID: "s1",
            playbackEpisode: nil, watchedEpisodes: watchedEpisodes
        ) { $0.canDelete }
    }

    /// Last, set apart below a divider (Benjamin, 2026-11-19).
    func test_watchedEpisodes_comesLast() {
        let targets = targets(watchedEpisodes: watched(2, of: 5))
        XCTAssertEqual(targets.deleteRequests.map(\.id), ["show", "s1", "ep", "watched.show"])
    }

    func test_watchedEpisodes_offeredWhenTheShowIsNotDeletable() {
        let targets = targets(showCanDelete: false, watchedEpisodes: watched(2, of: 5))
        XCTAssertEqual(targets.deleteRequests.map(\.id), ["s1", "ep", "watched.show"])
    }

    func test_noWatchedEpisodes_offersNoRow() {
        let targets = targets(watchedEpisodes: nil)
        XCTAssertEqual(targets.deleteRequests.map(\.id), targets.deletable.map(\.id))
    }

    func test_watchedRow_isNamedAllWatched() {
        let request = AssetDeleteRequest.watchedEpisodes(watched(2, of: 5))
        XCTAssertEqual(request.rowLabel, "All Watched")
        XCTAssertEqual(request.actionLabel, "Delete Watched Episodes")
        XCTAssertEqual(request.affectedItemIDs, ["w1", "w2"])
    }

    func test_watchedMessage_plural() {
        XCTAssertEqual(
            AssetActionTargets.deleteWatchedConfirmationMessage(for: watched(12, of: 40)),
            "12 episodes that are watched will be deleted for all users. 28 episodes will remain for House of Games. This cannot be undone."
        )
    }

    func test_watchedMessage_singular() {
        XCTAssertEqual(
            AssetActionTargets.deleteWatchedConfirmationMessage(for: watched(1, of: 2)),
            "1 episode that is watched will be deleted for all users. 1 episode will remain for House of Games. This cannot be undone."
        )
    }

    func test_watchedMessage_noneRemain() {
        XCTAssertEqual(
            AssetActionTargets.deleteWatchedConfirmationMessage(for: watched(3, of: 3)),
            "3 episodes that are watched will be deleted for all users. No episodes will remain, and House of Games will be removed. This cannot be undone."
        )
    }

    func test_itemRequest_keepsTodaysCopy() {
        let request = AssetDeleteRequest.item(season1)
        XCTAssertEqual(request.id, "s1")
        XCTAssertEqual(request.rowLabel, "Season 1")
        XCTAssertEqual(request.actionLabel, "Delete Season")
        XCTAssertEqual(request.confirmationMessage, AssetActionTargets.deleteConfirmationMessage(for: season1))
        XCTAssertEqual(request.affectedItemIDs, ["s1"])
    }
}
