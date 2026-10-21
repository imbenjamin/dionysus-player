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
        let targets = AssetActionTargets(item: movie, seriesItem: nil, seasons: [], selectedSeasonID: nil) { _ in false }
        XCTAssertEqual(targets.addable.map(\.id), ["movie"])
        XCTAssertEqual(targets.deletable.map(\.id), ["movie"])
    }

    func test_movieWithoutCanDelete_isAddableButNotDeletable() {
        let movie = item("movie", .movie, canDelete: false)
        let targets = AssetActionTargets(item: movie, seriesItem: nil, seasons: [], selectedSeasonID: nil) { _ in false }
        XCTAssertEqual(targets.addable.map(\.id), ["movie"])
        XCTAssertTrue(targets.deletable.isEmpty)
    }

    func test_seriesPage_offersShowAndSelectedSeason_neverAnEpisode() {
        let targets = AssetActionTargets(
            item: show, seriesItem: show, seasons: [season1, season2], selectedSeasonID: "s2"
        ) { $0.canDelete }
        XCTAssertEqual(targets.addable.map(\.id), ["show", "s2"])
        XCTAssertEqual(targets.deletable.map(\.id), ["show", "s2"])
    }

    func test_episodePage_offersShowSeasonEpisode_inThatOrder() {
        let episode = item("e4", .episode, season: 2, episode: 4)
        let targets = AssetActionTargets(
            item: episode, seriesItem: show, seasons: [season1, season2], selectedSeasonID: "s2"
        ) { $0.canDelete }
        XCTAssertEqual(targets.addable.map(\.id), ["show", "s2", "e4"])
        XCTAssertEqual(targets.deletable.map(\.id), ["show", "s2", "e4"])
    }

    func test_folderlessSeason_offeredOnlyWhenEveryEpisodeIsDeletable() {
        let folderless = item("s1", .season, canDelete: false)
        let before = AssetActionTargets(
            item: show, seriesItem: show, seasons: [folderless], selectedSeasonID: "s1"
        ) { _ in false }
        XCTAssertEqual(before.deletable.map(\.id), ["show"])
        XCTAssertEqual(before.addable.map(\.id), ["show", "s1"], "Adding has no permission gate.")

        let after = AssetActionTargets(
            item: show, seriesItem: show, seasons: [folderless], selectedSeasonID: "s1"
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
}
