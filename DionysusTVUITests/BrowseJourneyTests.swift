import XCTest

final class BrowseJourneyTests: TVUITestCase {
    /// A signed-in launch shows the rails, with focus on the first tile of the
    /// first one, Continue Watching. Later rails sit off screen in a lazy stack,
    /// so the journey reads the rail that is on screen.
    func test_signedIn_showsRailsWithFocusOnFirstTile() {
        let app = launch(seedSession: true)
        let tile = app.buttons[A11yID.TV.Main.tile(UITestFixtureIdentity.partWatchedMovieID)]
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFocus(tile))
    }
}
