import UIKit
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
    /// a Restart button — `PlayResumeButtonRow`'s `canResume` branch. The
    /// fixture is played with a position (a rewatch stopped partway), which
    /// once read Play.
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

    /// A show whose seasons exist but hold no episodes: no Play button that
    /// would do nothing, and the episode list says why it's empty.
    func testShowWithNoEpisodesHidesPlayAndSaysSo() {
        launch(scenario: "showWithoutEpisodes")
        let home = HomeScreen(app: app)
        home.awaitLoaded()
        home.openItem(UITestFixtureIdentity.showsLibraryID)

        let collection = CollectionScreen(app: app)
        collection.awaitLoaded(UITestFixtureIdentity.seriesID)
        collection.card(UITestFixtureIdentity.seriesID).tap()

        let detail = AssetDetailScreen(app: app)
        detail.noEpisodesMessage.awaitExistence("the no-episodes message")
        // A disappearance wait, not `exists`: the page renders from the grid's
        // preloaded item while `load()` is still resolving a play target.
        detail.playButton.awaitDisappearance("the Play button on a show with no episodes")
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

    /// A playlist with a description gets the About panel; one without gets
    /// no panel at all, rather than a pooled genre list over "No synopsis
    /// available." (see `PlaylistDetailView`). The fixture's main playlist
    /// has a description and `secondPlaylist` has none.
    func testPlaylistAboutPanelShowsOnlyWithADescription() {
        launch()
        let home = HomeScreen(app: app)
        home.awaitLoaded()
        home.openLibrary(UITestFixtureIdentity.playlistsLibraryID)

        let collection = CollectionScreen(app: app)
        collection.awaitLoaded(UITestFixtureIdentity.playlistID)
        collection.card(UITestFixtureIdentity.playlistID).tap()

        let detail = AssetDetailScreen(app: app)
        detail.awaitLoaded()
        detail.synopsis.awaitExistence("the playlist's description")

        app.navigationBackButton.tap()
        collection.awaitLoaded(UITestFixtureIdentity.secondPlaylistID)
        collection.card(UITestFixtureIdentity.secondPlaylistID).tap()

        // An empty playlist has nothing to play, so wait on the favourite
        // button instead of Play.
        detail.favoriteButton.awaitExistence("the second playlist's favourite button")
        XCTAssertFalse(detail.synopsis.exists, "A playlist without a description shouldn't show the About panel.")
    }

    // MARK: - Deletion

    /// The permission gate. `.noDeletePermission` serves the same catalogue
    /// with `CanDelete: false` on every item, and the affordance must be
    /// absent entirely — not merely disabled, which would advertise a
    /// permission the user hasn't got.
    ///
    /// The overflow itself stays: `AssetActionsButton` always draws the
    /// `ellipsis` menu, so its kind never changes once `CanDelete` arrives
    /// (see its "Which control gets drawn"). So this asserts the gate one
    /// level in — the menu opens, "Add to Playlist" is in it, "Delete" isn't.
    func testDeleteButtonIsHiddenWithoutServerPermission() {
        launch(scenario: "noDeletePermission")
        let home = HomeScreen(app: app)
        home.awaitLoaded()
        home.openItem(UITestFixtureIdentity.primaryMovieID)

        let detail = AssetDetailScreen(app: app)
        detail.awaitLoaded()
        detail.moreButton.awaitExistence("the actions overflow")
        detail.moreButton.tap()
        detail.addToPlaylistButton.awaitExistence("the Add to Playlist action")
        XCTAssertFalse(detail.deleteButton.exists, "Delete must not be offered without server permission.")
    }

    /// The same page, with permission, does offer it, below Add to Playlist
    /// in the same overflow.
    func testDeleteButtonIsShownWithServerPermission() {
        launch()
        let home = HomeScreen(app: app)
        home.awaitLoaded()
        home.openItem(UITestFixtureIdentity.primaryMovieID)

        let detail = AssetDetailScreen(app: app)
        detail.awaitLoaded()
        detail.moreButton.awaitExistence("the actions overflow")
        detail.moreButton.tap()
        detail.deleteButton.awaitExistence("the delete action")
    }

    /// Raising the dialog must not itself delete anything, and the warning
    /// has to actually say the content leaves the server irreversibly —
    /// this is the only thing standing between a mis-tap and a deleted
    /// file, so the copy is worth asserting rather than assuming.
    ///
    /// Doesn't tap Cancel: anchored to a toolbar button, iOS renders this
    /// as a popover and omits the cancel action entirely, dismissing on a
    /// tap outside instead (confirmed against the live accessibility tree —
    /// no Cancel element exists). Tap-away dismissal is exactly the
    /// synthetic-coordinate gesture this suite avoids elsewhere.
    func testConfirmationWarnsBeforeAnythingIsDeleted() {
        launch()
        let home = HomeScreen(app: app)
        home.awaitLoaded()
        home.openItem(UITestFixtureIdentity.primaryMovieID)

        let detail = AssetDetailScreen(app: app)
        detail.awaitLoaded()
        detail.openDelete()
        detail.deleteConfirmButton.awaitExistence("the delete confirmation")

        let warning = app.sheets.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "This cannot be undone")
        ).firstMatch
        XCTAssertTrue(warning.exists, "The dialog must warn that deletion is irreversible.")
        XCTAssertTrue(
            warning.label.contains("Jellyfin server"),
            "The warning must say the item leaves the server, not just the app. Was: \(warning.label)"
        )

        // Nothing has been confirmed, so the item is still there.
        XCTAssertTrue(detail.playButton.exists, "Merely opening the dialog must not delete anything.")
    }

    /// The whole movie flow end to end: confirm, the server accepts it, the
    /// page pops, and the grid it returns to no longer lists the item.
    ///
    /// Reached via the movies grid rather than a Home rail so there's a
    /// deterministic list to assert the disappearance against — see
    /// `CollectionGridViewModel.removeDeletedItem(itemID:)`.
    func testDeletingAMoviePopsBackAndRemovesItFromTheGrid() {
        launch()
        let home = HomeScreen(app: app)
        home.awaitLoaded()
        home.openItem(UITestFixtureIdentity.moviesLibraryID)

        let collection = CollectionScreen(app: app)
        collection.awaitLoaded(UITestFixtureIdentity.primaryMovieID)
        collection.card(UITestFixtureIdentity.primaryMovieID).tap()

        let detail = AssetDetailScreen(app: app)
        detail.awaitLoaded()
        detail.openDelete()
        detail.confirmDelete()

        // Back on the grid, with the tile gone.
        collection.awaitLoaded(UITestFixtureIdentity.movieID(2))
        XCTAssertFalse(
            app.otherElements[A11yID.Media.card(UITestFixtureIdentity.primaryMovieID)].exists,
            "The deleted movie should no longer have a tile."
        )
    }

    /// A show page offers its selected season in the Delete submenu, says how
    /// many episodes go with it, and after the delete stays on the show with
    /// the picker moved to the season that's left.
    ///
    /// The stub serves a season's `CanDelete` and episode count only when the
    /// request asks for them, as Jellyfin does, so the row's presence and the
    /// "all 3 episodes" copy both prove the season list asks.
    func testDeletingASeasonStaysOnTheShowAndMovesToTheNextSeason() {
        launch()
        let home = HomeScreen(app: app)
        home.awaitLoaded()
        home.openItem(UITestFixtureIdentity.showsLibraryID)

        let collection = CollectionScreen(app: app)
        collection.awaitLoaded(UITestFixtureIdentity.seriesID)
        collection.card(UITestFixtureIdentity.seriesID).tap()

        let detail = AssetDetailScreen(app: app)
        detail.awaitLoaded()
        detail.episodeRow(UITestFixtureIdentity.episodeID(season: 1, episode: 1))
            .awaitExistence("Season 1's first episode, the selected season")

        detail.openDelete()
        let seasonRow = detail.deleteTarget("Season 1")
        seasonRow.awaitExistence("the Season row in the Delete submenu")
        XCTAssertTrue(
            detail.deleteTarget(UITestFixtureIdentity.seriesName).exists,
            "The show itself should still be offered beside its season."
        )
        seasonRow.tap()

        detail.deleteConfirmButton.awaitExistence("the season delete confirmation")
        let warning = app.sheets.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "all 3 episodes")
        ).firstMatch
        XCTAssertTrue(warning.exists, "The dialog should say how many episodes the season takes with it.")
        detail.confirmDelete()

        // Still on the show, now on Season 2.
        detail.episodeRow(UITestFixtureIdentity.episodeID(season: 2, episode: 1))
            .awaitExistence("Season 2's first episode, once the picker moves off the deleted season")
        XCTAssertFalse(
            detail.episodeRow(UITestFixtureIdentity.episodeID(season: 1, episode: 1)).exists,
            "The deleted season's episodes should be gone."
        )
        XCTAssertTrue(detail.playButton.exists, "Deleting one of two seasons should leave the show page up.")
        XCTAssertFalse(detail.playButton.label.contains("S1:E"), "Play should leave Season 1. Was: \(detail.playButton.label)")
    }

    /// A show page offers the episode Play starts for deletion too (Benjamin,
    /// 2026-10-26). The stub's Next Up serves `CanDelete` only when asked, so
    /// the row's presence proves the lookup asks. Deleting it keeps the page
    /// on the show, and Play moves on.
    func testShowPageOffersTheEpisodePlayStartsForDeletion() {
        launch()
        let home = HomeScreen(app: app)
        home.awaitLoaded()
        home.openItem(UITestFixtureIdentity.showsLibraryID)

        let collection = CollectionScreen(app: app)
        collection.awaitLoaded(UITestFixtureIdentity.seriesID)
        collection.card(UITestFixtureIdentity.seriesID).tap()

        let detail = AssetDetailScreen(app: app)
        detail.awaitLoaded()
        // Read from Play, not the episode's row: the list is a `Lazy` stack,
        // and on a short window (a closed iPhone Duo's 678pt) Episode 2's row
        // sits past what's materialized without a scroll.
        let playsNextUp = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "S1:E2"),
            object: detail.playButton
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [playsNextUp], timeout: Self.defaultTimeout), .completed,
            "Play should start Season 1's second episode, Next Up."
        )
        let nextUp = detail.episodeRow(UITestFixtureIdentity.episodeID(season: 1, episode: 2))

        detail.openDelete()
        let row = detail.deleteTarget("S1:E2 \u{00B7} Episode 2")
        row.awaitExistence("the Play episode's row in the Delete submenu")
        XCTAssertTrue(detail.deleteTarget(UITestFixtureIdentity.seriesName).exists)
        XCTAssertTrue(detail.deleteTarget("Season 1").exists)
        row.tap()

        let warning = app.sheets.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "Episode 2")
        ).firstMatch
        XCTAssertTrue(warning.waitForExistence(timeout: 5), "The dialog names the episode it deletes.")
        detail.confirmDelete()

        nextUp.awaitDisappearance("the deleted episode's row")
        XCTAssertTrue(
            detail.episodeRow(UITestFixtureIdentity.episodeID(season: 1, episode: 1)).exists,
            "The rest of the season stays."
        )
        XCTAssertTrue(detail.playButton.exists, "Still the show's page.")
        XCTAssertFalse(detail.playButton.label.contains("S1:E2"), "Play leaves the deleted episode. Was: \(detail.playButton.label)")
    }

    /// An episode page offers all three: the episode, its season and the
    /// show. Deleting the season from there takes the episode on show with it,
    /// so the page goes back to the show, on the season that's left.
    func testEpisodePageOffersEpisodeSeasonAndShowForDeletion() {
        launch()
        let home = HomeScreen(app: app)
        home.awaitLoaded()
        home.openItem(UITestFixtureIdentity.showsLibraryID)

        let collection = CollectionScreen(app: app)
        collection.awaitLoaded(UITestFixtureIdentity.seriesID)
        collection.card(UITestFixtureIdentity.seriesID).tap()

        let detail = AssetDetailScreen(app: app)
        detail.awaitLoaded()
        let episodeRow = detail.episodeRow(UITestFixtureIdentity.episodeID(season: 1, episode: 1))
        episodeRow.awaitExistence("the Season 1, Episode 1 row")
        episodeRow.tap()

        detail.openDelete()
        detail.deleteTarget(UITestFixtureIdentity.seriesName).awaitExistence("the Show row in the Delete submenu")
        XCTAssertTrue(detail.deleteTarget("Season 1").exists, "An episode page should offer its season.")
        XCTAssertTrue(detail.deleteTarget("S1:E1 \u{00B7} Episode 1").exists, "An episode page should offer the episode.")

        detail.deleteTarget("Season 1").tap()
        detail.confirmDelete()

        detail.episodeRow(UITestFixtureIdentity.episodeID(season: 2, episode: 1))
            .awaitExistence("Season 2's first episode, once the season on show is gone")
        XCTAssertFalse(
            detail.episodeRow(UITestFixtureIdentity.episodeID(season: 1, episode: 1)).exists,
            "The deleted season's episodes should be gone."
        )
        // Back on the show: Play no longer targets a deleted episode.
        XCTAssertFalse(detail.playButton.label.contains("S1:E"), "Play should leave Season 1. Was: \(detail.playButton.label)")
    }

    /// A show whose episodes sit loose in its folder: Jellyfin makes its
    /// seasons up and won't delete one as a unit, so Delete Season is offered
    /// on its episodes' say-so and deletes them one by one. Driven from an
    /// episode page, where it was first missed.
    func testFolderlessSeasonIsDeletedEpisodeByEpisode() {
        launch(scenario: "folderlessSeasons")
        let home = HomeScreen(app: app)
        home.awaitLoaded()
        home.openItem(UITestFixtureIdentity.showsLibraryID)

        let collection = CollectionScreen(app: app)
        collection.awaitLoaded(UITestFixtureIdentity.seriesID)
        collection.card(UITestFixtureIdentity.seriesID).tap()

        let detail = AssetDetailScreen(app: app)
        detail.awaitLoaded()
        let episodeRow = detail.episodeRow(UITestFixtureIdentity.episodeID(season: 1, episode: 1))
        episodeRow.awaitExistence("the Season 1, Episode 1 row")
        episodeRow.tap()

        detail.openDelete()
        detail.deleteTarget("Season 1").awaitExistence("the folderless Season row in the Delete submenu")
        XCTAssertTrue(detail.deleteTarget(UITestFixtureIdentity.seriesName).exists, "The show should be offered too.")
        XCTAssertTrue(detail.deleteTarget("S1:E1 \u{00B7} Episode 1").exists, "The episode should be offered too.")

        detail.deleteTarget("Season 1").tap()
        detail.confirmDelete()

        detail.episodeRow(UITestFixtureIdentity.episodeID(season: 2, episode: 1))
            .awaitExistence("Season 2's first episode, once Season 1's episodes are gone")
        XCTAssertFalse(
            detail.episodeRow(UITestFixtureIdentity.episodeID(season: 1, episode: 1)).exists,
            "The deleted season's episodes should be gone."
        )
        XCTAssertFalse(detail.playButton.label.contains("S1:E"), "Play should leave Season 1. Was: \(detail.playButton.label)")
    }

    // MARK: - Playlist item removal

    /// The only removal path this feature has: long-press a row, tap
    /// "Remove from Playlist" in the resulting context menu, and the row
    /// is gone. `UITestFixtureLibrary.playlistMembers` stamps
    /// `"playlist-entry-1"` on its first member — see that property's doc
    /// comment. (A hand-rolled swipe gesture sat alongside this once —
    /// see `PlaylistItemList.onRemove`'s doc comment for why it was
    /// reverted.)
    func testRemovingAPlaylistItemViaContextMenu() {
        launch()
        let home = HomeScreen(app: app)
        home.awaitLoaded()
        home.openLibrary(UITestFixtureIdentity.playlistsLibraryID)

        let collection = CollectionScreen(app: app)
        collection.awaitLoaded(UITestFixtureIdentity.playlistID)
        collection.card(UITestFixtureIdentity.playlistID).tap()

        let detail = AssetDetailScreen(app: app)
        detail.awaitLoaded()
        detail.playlistRow("playlist-entry-1").awaitExistence("the first playlist row")

        detail.removePlaylistItem("playlist-entry-1")

        XCTAssertFalse(
            detail.playlistRow("playlist-entry-1").exists,
            "The removed row should be gone from the playlist."
        )
        // A different row is untouched — this removed one entry, not the
        // whole list.
        XCTAssertTrue(
            detail.playlistRow("playlist-entry-2").exists,
            "Removing one row must not affect the others."
        )
    }

    /// The permission gate. `.noPlaylistEditPermission` serves the same
    /// catalogue but answers this playlist's own permission lookup with
    /// "not permitted" — the remove action must be entirely absent from
    /// the context menu, not merely disabled.
    func testPlaylistRemoveMenuItemAbsentWithoutEditPermission() {
        launch(scenario: "noPlaylistEditPermission")
        let home = HomeScreen(app: app)
        home.awaitLoaded()
        home.openLibrary(UITestFixtureIdentity.playlistsLibraryID)

        let collection = CollectionScreen(app: app)
        collection.awaitLoaded(UITestFixtureIdentity.playlistID)
        collection.card(UITestFixtureIdentity.playlistID).tap()

        let detail = AssetDetailScreen(app: app)
        detail.awaitLoaded()
        let row = detail.playlistRow("playlist-entry-1")
        row.awaitExistence("the first playlist row")
        row.press(forDuration: 1.0)

        XCTAssertFalse(
            detail.playlistRemoveMenuItem("playlist-entry-1").waitForExistence(timeout: 2),
            "Remove from Playlist must not be offered without edit permission on this playlist."
        )
    }

    /// The hero's backdrop reaches both screen edges in landscape, where the
    /// page's scroll view keeps a horizontal safe area (the Dynamic Island's
    /// side, and on a closed iPhone Duo the vertical bar's column). Read from
    /// the pixels: the backdrop is accessibility-hidden, and the fixture's is
    /// dark against the light page, so a backdrop stopping at the safe area
    /// leaves a light strip at the edge. Skipped on an iPhone Duo: its inner
    /// display held wide shows a book spread instead of the hero, and closed
    /// the Simulator can't be turned from here
    /// (`skipWhereXCUIDeviceCannotRotate()`).
    func testHeroBackdropReachesTheScreenEdgesInLandscape() throws {
        let device = XCUIDevice.shared
        addTeardownBlock { @MainActor in device.orientation = .portrait }
        launch()
        let home = HomeScreen(app: app)
        home.awaitLoaded()
        home.openItem(UITestFixtureIdentity.primaryMovieID)
        let detail = AssetDetailScreen(app: app)
        detail.awaitLoaded()
        if detail.isBookSpread {
            throw XCTSkip("A book spread shows the poster instead of the hero.")
        }

        let window = app.windows.firstMatch
        if window.frame.width <= window.frame.height {
            try skipWhereXCUIDeviceCannotRotate()
            device.orientation = .landscapeLeft
        }
        let landscape = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in window.frame.width > window.frame.height },
            object: nil
        )
        XCTAssertEqual(XCTWaiter().wait(for: [landscape], timeout: Self.defaultTimeout), .completed)
        // Let the rotation and the hero's height settle.
        _ = XCTWaiter().wait(for: [XCTestExpectation(description: "settle")], timeout: 2)

        let image = window.screenshot().image
        XCTAssertGreaterThan(image.size.width, image.size.height, "The screenshot should be upright in landscape.")
        let y = image.size.height * 0.4
        for x in [2, image.size.width - 2] {
            XCTAssertLessThan(
                Self.brightness(of: image, at: CGPoint(x: x, y: y)), 0.5,
                "The backdrop should reach the screen edge at x = \(Int(x))pt, not stop at the safe area."
            )
        }
    }

    /// The brightness, 0 to 1, of the pixel under `point` (in points): the
    /// mean of its three colour channels, whichever order they come in.
    private static func brightness(of image: UIImage, at point: CGPoint) -> CGFloat {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let pixel = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1), format: format).image { _ in
            image.draw(at: CGPoint(x: -point.x, y: -point.y))
        }
        guard let data = pixel.cgImage?.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return 1 }
        return (CGFloat(bytes[0]) + CGFloat(bytes[1]) + CGFloat(bytes[2])) / (3 * 255)
    }
}
