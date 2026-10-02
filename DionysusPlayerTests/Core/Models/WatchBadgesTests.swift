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

    /// A played item can still carry a resume position; the bar is only for
    /// something part-watched.
    func test_played_showsTheEye_andNoProgress() {
        let badges = WatchBadges(isFavorite: false, isPlayed: true, playedFraction: 0.9)
        XCTAssertTrue(badges.showsWatched)
        XCTAssertNil(badges.progress)
    }

    func test_favoriteAndWatched_showTogether() {
        let badges = WatchBadges(isFavorite: true, isPlayed: true, playedFraction: nil)
        XCTAssertTrue(badges.showsFavorite)
        XCTAssertTrue(badges.showsWatched)
    }
}
