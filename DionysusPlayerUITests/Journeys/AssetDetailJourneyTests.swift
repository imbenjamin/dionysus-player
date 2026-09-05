import XCTest

/// The four detail layouts (movie, show → episode, box set, playlist) and
/// the favourite/watched toggles, reached the same way
/// `SmokeJourneyTests`/`CollectionJourneyTests` already reach individual
/// items — a library card, then a grid tile.
///
/// Box set *membership* browsing isn't covered here: `CollectionItemList`'s
/// row is a `Lazy` stack, and this fixture's members sit past what a fixed
/// window materializes without a scroll — the same scroll-gesture
/// unreliability the rest of this suite already avoids. Favourite/watched
/// and reachability are covered instead.
final class AssetDetailJourneyTests: UITestCase {
    /// The primary fixture movie starts favourited and unwatched. Toggling
    /// either flips the button's own accessibility label, which is the
    /// simplest live signal that the state round-tripped through
    /// `AssetDetailViewModel` at all.
    func testFavoriteAndWatchedTogglesFlipTheirLabels() {
        launch()
        let home = HomeScreen(app: app)
        home.awaitLoaded()
        home.openItem(UITestFixtureIdentity.primaryMovieID)

        let detail = AssetDetailScreen(app: app)
        detail.awaitLoaded()

        XCTAssertEqual(detail.favoriteButton.label, "Remove from Favorites")
        detail.favoriteButton.tap()
        XCTAssertEqual(detail.favoriteButton.label, "Add to Favorites")

        XCTAssertEqual(detail.watchedButton.label, "Mark as Watched")
        detail.watchedButton.tap()
        XCTAssertEqual(detail.watchedButton.label, "Mark as Unwatched")
    }

    /// The one part-watched fixture movie shows Resume (not Play) alongside
    /// a Restart button — `PlayResumeButtonRow`'s branch for
    /// `playedFraction > 0`.
    func testPartWatchedMovieShowsResumeAndRestart() {
        launch()
        let home = HomeScreen(app: app)
        home.awaitLoaded()
        home.openItem(UITestFixtureIdentity.moviesLibraryID)

        let collection = CollectionScreen(app: app)
        collection.awaitLoaded(UITestFixtureIdentity.partWatchedMovieID)
        collection.card(UITestFixtureIdentity.partWatchedMovieID).tap()

        let detail = AssetDetailScreen(app: app)
        detail.awaitLoaded()
        XCTAssertTrue(detail.playButton.label.contains("Resume"), "A part-watched movie should offer Resume, not Play.")
        detail.restartButton.awaitExistence("the Restart button next to Resume")
    }

    /// Selecting a different episode switches `ShowDetailView`'s own
    /// content in place (no push — see `SeasonEpisodeList.onSelectEpisode`'s
    /// doc comment), which this asserts via the Play button's label
    /// changing to name the newly-selected episode.
    ///
    /// Targets Season 1 Episode 1 specifically, not a later one: the
    /// episode list is a `Lazy` stack, and on iPhone's narrower layout a
    /// later row can sit past what's materialized without a scroll — the
    /// same scroll-gesture unreliability `AssetDetailJourneyTests`'s own
    /// doc comment already avoids for box set membership. Episode 1 is also
    /// never the page's own default selection (that's Episode 2 — Jellyfin's
    /// own "next up" resolution, since Episode 1 is the fixture's
    /// part-watched one), so switching to it is still a real, detectable
    /// change.
    func testSelectingAnEpisodeUpdatesThePlayButton() {
        launch()
        let home = HomeScreen(app: app)
        home.awaitLoaded()
        home.openItem(UITestFixtureIdentity.showsLibraryID)

        let collection = CollectionScreen(app: app)
        collection.awaitLoaded(UITestFixtureIdentity.seriesID)
        collection.card(UITestFixtureIdentity.seriesID).tap()

        let detail = AssetDetailScreen(app: app)
        detail.awaitLoaded()
        let initialLabel = detail.playButton.label

        let otherEpisodeRow = detail.episodeRow("episode-s1e1")
        otherEpisodeRow.awaitExistence("the Season 1, Episode 1 row")
        otherEpisodeRow.tap()

        XCTAssertNotEqual(
            detail.playButton.label, initialLabel,
            "Selecting a different episode should update which one Play targets."
        )
        // Not a "contains S1:E1" check: Episode 1 is the fixture's
        // part-watched one, and `PlayResumeButtonRow.accessibilityLabelText`
        // drops the "SXX:EYY" suffix for a resumable item in favor of
        // "Resume from <duration>" — confirmed live. "Resume" is what
        // actually distinguishes this from the initial (unwatched) episode's
        // label.
        XCTAssertTrue(detail.playButton.label.contains("Resume"), "Play should now offer to resume the selected episode.")
    }

    /// A box set has no play button of its own (it isn't playable), but
    /// still exposes favourite/watched — for the collection as a whole.
    func testBoxSetDetailHasNoPlayButtonButHasFavoriteAndWatched() {
        launch()
        let home = HomeScreen(app: app)
        home.awaitLoaded()
        home.openLibrary(UITestFixtureIdentity.boxSetsLibraryID)

        let collection = CollectionScreen(app: app)
        collection.awaitLoaded(UITestFixtureIdentity.boxSetID)
        collection.card(UITestFixtureIdentity.boxSetID).tap()

        let detail = AssetDetailScreen(app: app)
        detail.favoriteButton.awaitExistence("the box set's favourite button")
        XCTAssertFalse(detail.playButton.exists, "A box set shouldn't offer a direct Play action.")
    }

    /// A playlist, unlike a box set, is itself playable — same shared Play
    /// button as a movie or episode.
    func testPlaylistDetailHasAPlayButton() {
        launch()
        let home = HomeScreen(app: app)
        home.awaitLoaded()
        home.openLibrary(UITestFixtureIdentity.playlistsLibraryID)

        let collection = CollectionScreen(app: app)
        collection.awaitLoaded(UITestFixtureIdentity.playlistID)
        collection.card(UITestFixtureIdentity.playlistID).tap()

        AssetDetailScreen(app: app).awaitLoaded()
    }
}
