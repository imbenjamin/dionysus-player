import XCTest

/// The Movies library grid's sort/filter/random controls — reached the same
/// way `SmokeJourneyTests.testOpeningAnItemFromACollectionGrid` does, via
/// the library card on Home.
final class CollectionJourneyTests: UITestCase {
    /// `Signal Fire` (the fixture's one part-watched movie) is Sci-Fi, so
    /// narrowing to Genre=Action should hide it while an actual Action title
    /// stays visible; Reset restores the original, unfiltered grid.
    func testFilteringByGenreNarrowsTheGridAndResetRestoresIt() {
        launch()
        let home = HomeScreen(app: app)
        home.awaitLoaded()
        home.openItem(UITestFixtureIdentity.moviesLibraryID)

        let collection = CollectionScreen(app: app)
        collection.awaitLoaded(UITestFixtureIdentity.partWatchedMovieID)
        let sciFiMovie = collection.card(UITestFixtureIdentity.partWatchedMovieID)
        let actionMovie = collection.card(UITestFixtureIdentity.movieID(4))

        collection.filterPill("genre").tap()
        collection.selectFilterOption("Action")

        sciFiMovie.awaitDisappearance("the filtered-out Sci-Fi title")
        XCTAssertTrue(actionMovie.exists, "An Action title should remain visible under Genre=Action.")

        collection.resetFiltersButton.tap()
        sciFiMovie.awaitExistence("the Sci-Fi title once filters are reset")
    }

    /// `Iron Meridian` is the fixture catalogue's only movie that's both
    /// Action and a favourite — combining those two facets should leave
    /// exactly that one title, never the "no matches" state the cascading
    /// facets (`CollectionGridViewModel.matchingItems`) are supposed to make
    /// unreachable through this UI.
    func testCombiningTwoFiltersNeverEmptiesTheGrid() {
        launch()
        let home = HomeScreen(app: app)
        home.awaitLoaded()
        home.openItem(UITestFixtureIdentity.moviesLibraryID)

        let collection = CollectionScreen(app: app)
        collection.awaitLoaded(UITestFixtureIdentity.partWatchedMovieID)

        collection.filterPill("genre").tap()
        collection.selectFilterOption("Action")

        collection.filterPill("favorites").tap()
        collection.selectFilterOption("Favorites")

        collection.card(UITestFixtureIdentity.movieID(4))
            .awaitExistence("the one title matching both Genre=Action and Favorites")
        XCTAssertFalse(
            collection.noFilterMatches.exists,
            "Two compatible filters should never empty the grid."
        )
    }

    /// `randomItem()` is genuinely random (`Array.randomElement()`), so this
    /// only asserts the dice button routes somewhere real, not to a
    /// specific item.
    func testRandomButtonOpensAnItem() {
        launch()
        let home = HomeScreen(app: app)
        home.awaitLoaded()
        home.openItem(UITestFixtureIdentity.moviesLibraryID)

        let collection = CollectionScreen(app: app)
        collection.awaitLoaded(UITestFixtureIdentity.partWatchedMovieID)
        collection.randomButton.tap()

        AssetDetailScreen(app: app).awaitLoaded()
    }
}
