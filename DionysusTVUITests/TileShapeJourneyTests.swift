import XCTest

/// One tile shape per rail or grid, decided as on iOS (Benjamin, 2026-10-05):
/// posters for movies alone, landscape thumbs once a show or an episode is
/// in it. Shape is read from the focusable tile's frame.
final class TileShapeJourneyTests: TVUITestCase {
    private func isLandscape(_ tile: XCUIElement) -> Bool { tile.frame.width > tile.frame.height }

    func test_aShowsLibrary_isAGridOfLandscapeTiles() {
        let app = launchAtHome()
        openRailFromHome(app)
        pressDown(until: app.buttons[A11yID.TV.Sidebar.library(UITestFixtureIdentity.showsLibraryID)])
        press(.select)
        let show = app.buttons[A11yID.TV.Library.tile(UITestFixtureIdentity.seriesID)]
        XCTAssertTrue(show.waitForExistence(timeout: 10))
        XCTAssertTrue(isLandscape(show), "A shows-only grid draws landscape thumbs")
    }

    func test_aMoviesLibrary_staysAGridOfPosters() {
        let app = launchAtHome()
        _ = openMovies(app)
        XCTAssertFalse(isLandscape(firstLibraryTile(app)), "A movies-only grid draws posters")
    }

    func test_searchesShowsRail_isLandscape_andItsMoviesRailPosters() {
        let app = launchAtHome()
        openRailFromHome(app)
        press(.down)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Sidebar.search]))
        press(.select)
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Northern")
        let show = app.buttons[A11yID.TV.Search.result(UITestFixtureIdentity.seriesID)]
        XCTAssertTrue(show.waitForExistence(timeout: 10))
        XCTAssertTrue(isLandscape(show), "Shows draw landscape thumbs")
    }
}
