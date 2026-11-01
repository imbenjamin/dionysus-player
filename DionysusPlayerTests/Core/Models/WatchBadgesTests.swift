import XCTest
@testable import Dionysus

/// Which corner badges a tile shows: one rule for iOS's `PosterCard` and the
/// Apple TV tiles.
final class WatchBadgesTests: XCTestCase {
    func test_untouchedItem_showsNothing() {
        let badges = WatchBadges(isFavorite: false, isPlayed: false, playedFraction: nil)
        XCTAssertEqual(badges, WatchBadges(isFavorite: false, isPlayed: false, playedFraction: 0))
        XCTAssertFalse(badges.showsFavorite)
        XCTAssertFalse(badges.showsWatched)
        XCTAssertNil(badges.progress)
    }

    func test_partWatched_showsProgressOnly() {
        let badges = WatchBadges(isFavorite: false, isPlayed: false, playedFraction: 0.4)
        XCTAssertEqual(badges.progress, 0.4)
        XCTAssertFalse(badges.showsWatched)
    }

    /// Finished, or a fully watched show: a fraction but nothing to resume.
    func test_played_withNoResumePosition_showsTheEye_andNoProgress() {
        let badges = WatchBadges(isFavorite: false, isPlayed: true, playedFraction: 1)
        XCTAssertTrue(badges.showsWatched)
        XCTAssertNil(badges.progress)
    }

    /// A rewatch stopped partway keeps `Played` and stores a new position.
    func test_rewatchStoppedPartway_showsTheEye_andProgress() {
        let badges = WatchBadges(isFavorite: false, isPlayed: true, playedFraction: 0.4, hasResumePosition: true)
        XCTAssertTrue(badges.showsWatched)
        XCTAssertEqual(badges.progress, 0.4)
    }

    private let images = ImageURLBuilder(baseURL: URL(string: "https://jellyfin.example.com")!, accessToken: "tok")

    func test_itemInit_readsARewatchFromTheServersUserData() {
        let userData = UserItemDataDto(playbackPositionTicks: 12_000_000_000, playedPercentage: 21, played: true)
        let movie = BaseItemDto(id: "m", name: "Movie", type: .movie, userData: userData)
        let badges = WatchBadges(item: MediaItem(dto: movie, images: images))
        XCTAssertTrue(badges.showsWatched)
        XCTAssertEqual(badges.progress, 0.21)
    }

    func test_itemInit_aFinishedMovieShowsNoProgress() {
        let userData = UserItemDataDto(playbackPositionTicks: 0, playedPercentage: 100, played: true)
        let movie = BaseItemDto(id: "m", name: "Movie", type: .movie, userData: userData)
        XCTAssertNil(WatchBadges(item: MediaItem(dto: movie, images: images)).progress)
    }

    func test_itemInit_aPlayedShowHasNoPositionOfItsOwn() {
        let userData = UserItemDataDto(playbackPositionTicks: 12_000_000_000, playedPercentage: 21, played: true)
        let show = BaseItemDto(id: "s", name: "Show", type: .series, userData: userData)
        XCTAssertNil(WatchBadges(item: MediaItem(dto: show, images: images)).progress)
    }

    func test_favoriteAndWatched_showTogether() {
        let badges = WatchBadges(isFavorite: true, isPlayed: true, playedFraction: nil)
        XCTAssertTrue(badges.showsFavorite)
        XCTAssertTrue(badges.showsWatched)
    }
}
