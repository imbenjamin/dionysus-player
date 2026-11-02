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

        collection.openFilter("genre")
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

        collection.openFilter("genre")
        collection.selectFilterOption("Action")

        collection.openFilter("favorites")
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

    /// In book pose on the iPhone Duo, no filter pill (nor Reset) and no
    /// poster sits on the fold: Favorites straddled it (`FoldGapHStack`), and a
    /// column of posters did (`PosterGridMetrics`). A genre is picked so Reset
    /// shows and the row reaches past the fold. Open and flat both go back to
    /// the plain layout, so the test needs the pose from CI (`duoPose`).
    func testTheFilterPillsAndPostersStayOffTheDuoFold() throws {
        launch()
        let home = HomeScreen(app: app)
        home.awaitLoaded()
        home.openItem(UITestFixtureIdentity.moviesLibraryID)

        let collection = CollectionScreen(app: app)
        collection.awaitLoaded(UITestFixtureIdentity.partWatchedMovieID)
        guard duoPose == "book", let fold = duoFoldBand(), fold.height > fold.width else {
            throw XCTSkip("Only the iPhone Duo in book pose has a fold across the pills to clear.")
        }
        collection.openFilter("genre")
        collection.selectFilterOption("Action")

        let posters = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "media.card."))
        let controls = ["genre", "studio", "decade", "watched", "favorites"].map(collection.filterPill)
            + [collection.resetFiltersButton]
            + (0..<min(posters.count, 8)).map { posters.element(boundBy: $0) }
        let clear = NSPredicate { _, _ in
            controls.allSatisfy { !$0.exists || !$0.frame.intersects(fold) } && collection.resetFiltersButton.exists
        }
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: clear, object: nil)], timeout: Self.defaultTimeout)
        XCTAssertEqual(
            result, .completed,
            "No filter control or poster should overlap the fold \(fold): \(controls.map { "\($0.identifier) \($0.frame)" })."
        )
    }
}
