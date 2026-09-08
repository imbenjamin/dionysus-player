import XCTest

/// Adding an asset to a playlist, from the asset detail page's toolbar
/// through `AddToPlaylistSheet` and out to the server.
///
/// Reached the same way every other detail-page journey is — a library card,
/// then a grid tile — and asserted end-to-end where possible:
/// `UITestStubURLProtocol` records what an add or create actually sent, and
/// replays it into later responses, so "the movie is now in that playlist"
/// and "the new playlist exists" are both observable rather than inferred
/// from a request that may or may not have been made.
///
/// The permission gate lives on the *destination* side here, not on the
/// button: adding to a playlist is always offered, because creating one
/// needs no server permission (see `JellyfinAPIClient.createPlaylist`). What
/// varies is which existing playlists the picker lists.
final class AddToPlaylistJourneyTests: UITestCase {
    // MARK: - The picker's contents

    /// The `canEdit` filter, asserted in the direction that can actually
    /// fail: the catalogue's read-only playlist is visible everywhere else
    /// in the app, and must not be offered as a destination.
    func testPickerListsOnlyPlaylistsThisUserCanEdit() {
        launch()
        openPrimaryMovieDetail().openAddToPlaylist()

        let picker = AddToPlaylistScreen(app: app)
        picker.awaitLoaded()

        picker.playlistRow(UITestFixtureIdentity.playlistID)
            .awaitExistence("the editable playlist's row")
        picker.playlistRow(UITestFixtureIdentity.secondPlaylistID)
            .awaitExistence("the second editable playlist's row")
        XCTAssertFalse(
            picker.playlistRow(UITestFixtureIdentity.readOnlyPlaylistID).exists,
            "A playlist this user can't edit must not be offered as a destination."
        )
    }

    /// With no editable playlist at all, the picker still has something to
    /// offer — creating one is ungated. The explanatory footer is what tells
    /// the user why the list is empty rather than leaving a blank sheet.
    func testPickerWithNoEditablePlaylistsStillOffersCreating() {
        launch(scenario: "noPlaylistEditPermission")
        openPrimaryMovieDetail().openAddToPlaylist()

        let picker = AddToPlaylistScreen(app: app)
        picker.awaitLoaded()

        picker.emptyState.awaitExistence("the no-editable-playlists explanation")
        XCTAssertFalse(
            picker.playlistRow(UITestFixtureIdentity.playlistID).exists,
            "No playlist should be listed when this user can edit none of them."
        )
        XCTAssertTrue(picker.newPlaylistButton.isEnabled, "Creating a playlist needs no permission.")
    }

    // MARK: - Adding to an existing playlist

    /// The whole single-item flow: pick a playlist, and — with no
    /// confirmation, because one movie is one item — land back on the asset
    /// page with the movie now a member of that playlist.
    func testAddingAMovieToAPlaylistAddsItWithoutConfirming() {
        launch()
        let detail = openPrimaryMovieDetail()
        detail.openAddToPlaylist()

        let picker = AddToPlaylistScreen(app: app)
        picker.awaitLoaded()
        picker.playlistRow(UITestFixtureIdentity.secondPlaylistID).tap()

        // No confirmation for a single item — the sheet just closes.
        XCTAssertFalse(
            picker.addConfirmButton.waitForExistence(timeout: 2),
            "Adding one movie must not stop to confirm."
        )
        picker.newPlaylistButton.awaitDisappearance("the Add to Playlist sheet")
        detail.awaitLoaded()

        // The playlist now contains it. `secondPlaylist` ships empty, so
        // this row can only be what the add just put there.
        let playlistDetail = openSecondPlaylistDetail()
        playlistDetail.playlistRow(addedEntry(index: 1))
            .awaitExistence("the added movie's row in its new playlist")
    }

    /// A show expands server-side into every episode beneath it, so this one
    /// *does* stop to confirm — and the message has to say how many episodes
    /// are about to be appended, which is the whole point of asking.
    func testAddingAShowConfirmsAndNamesTheEpisodeCount() {
        launch()
        let detail = openSeriesDetail()
        detail.openAddToPlaylist()
        // A show page offers Show and the selected Season, so "Add to
        // Playlist" opens a submenu rather than the sheet directly.
        detail.addToPlaylistScope(UITestFixtureIdentity.seriesName).tap()

        let picker = AddToPlaylistScreen(app: app)
        picker.awaitLoaded()
        picker.playlistRow(UITestFixtureIdentity.secondPlaylistID).tap()

        picker.addConfirmButton.awaitExistence("the add confirmation")
        // `app.alerts`, not `app.sheets` — this confirmation is an `.alert`
        // so that it keeps its Cancel action; see `AddToPlaylistSheet`.
        let message = app.alerts.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "episodes")
        ).firstMatch
        XCTAssertTrue(message.exists, "Adding a whole show must say how many episodes that is.")
        XCTAssertTrue(
            message.label.contains(UITestFixtureIdentity.secondPlaylistName),
            "The confirmation must name the destination playlist. Was: \(message.label)"
        )

        picker.addConfirmButton.tap()
        picker.newPlaylistButton.awaitDisappearance("the Add to Playlist sheet")

        // The show arrived as its *episodes*, not as one series row — the
        // server expands a folder-shaped item, and the app deliberately
        // doesn't enumerate them itself.
        //
        // Asserted on the first two rows rather than all six: one POST of
        // one series id producing more than one member can only be that
        // expansion, and `PlaylistItemList` is a `Lazy` stack whose later
        // rows need a scroll to materialize — the gesture this suite avoids.
        let playlistDetail = openSecondPlaylistDetail()
        playlistDetail.playlistRow(addedEntry(index: 1))
            .awaitExistence("the first episode of the added show")
        playlistDetail.playlistRow(addedEntry(index: 2))
            .awaitExistence("a second episode — proof the show expanded rather than landing as one row")
    }

    // MARK: - Confirmation feedback

    /// A toast, not just a haptic. The sheet closes on success, so this is
    /// the only thing left on screen that says what happened — and it has to
    /// name the destination, since the sheet that named it has gone.
    func testAddingShowsAToastNamingThePlaylist() {
        launch()
        openPrimaryMovieDetail().openAddToPlaylist()

        let picker = AddToPlaylistScreen(app: app)
        picker.awaitLoaded()
        picker.playlistRow(UITestFixtureIdentity.secondPlaylistID).tap()

        let message = ToastScreen(app: app).awaitMessage()
        XCTAssertTrue(
            message.contains(UITestFixtureIdentity.secondPlaylistName),
            "The toast must name the destination playlist. Was: \(message)"
        )
    }

    func testCreatingAPlaylistShowsAToastNamingIt() {
        launch()
        openPrimaryMovieDetail().openAddToPlaylist()

        let picker = AddToPlaylistScreen(app: app)
        picker.awaitLoaded()
        picker.createPlaylist(named: "Weeknights")

        let message = ToastScreen(app: app).awaitMessage()
        XCTAssertTrue(
            message.contains("Weeknights"),
            "The toast must name the new playlist. Was: \(message)"
        )
    }

    // MARK: - The show/season confirmation's own buttons

    /// Two things reported from a device: the confirmation had no Cancel at
    /// all (the `confirmationDialog` form drops it inside a sheet — hence
    /// the `.alert`), and its action button said a bare "Add" rather than
    /// how many episodes that meant.
    func testShowConfirmationOffersCancelAndCountsWhatItWillAdd() {
        launch()
        openSeriesDetail().openAddToPlaylist()

        let detail = AssetDetailScreen(app: app)
        detail.addToPlaylistScope(UITestFixtureIdentity.seriesName).tap()

        let picker = AddToPlaylistScreen(app: app)
        picker.awaitLoaded()
        picker.playlistRow(UITestFixtureIdentity.secondPlaylistID).tap()

        picker.addConfirmButton.awaitExistence("the add confirmation")
        // The catalogue's series has six episodes across two seasons.
        XCTAssertEqual(picker.addConfirmButton.label, "Add 6 Episodes")
        picker.addCancelButton.awaitExistence("the add confirmation's Cancel button")
    }

    /// Cancelling really cancels: the dialog closes, the sheet stays put,
    /// and nothing was added.
    func testCancellingTheShowConfirmationAddsNothing() {
        launch()
        openSeriesDetail().openAddToPlaylist()

        let detail = AssetDetailScreen(app: app)
        detail.addToPlaylistScope(UITestFixtureIdentity.seriesName).tap()

        let picker = AddToPlaylistScreen(app: app)
        picker.awaitLoaded()
        picker.playlistRow(UITestFixtureIdentity.secondPlaylistID).tap()

        picker.addCancelButton.awaitExistence("the add confirmation's Cancel button")
        picker.addCancelButton.tap()

        XCTAssertTrue(picker.newPlaylistButton.exists, "Cancelling must leave the picker open.")
        XCTAssertFalse(
            ToastScreen(app: app).message.waitForExistence(timeout: 3),
            "Cancelling must not report a successful add."
        )
    }

    // MARK: - Already-added destinations

    /// A playlist that already holds the target is greyed out rather than
    /// hidden — and the catalogue's seeded playlist already holds the
    /// primary movie, so this needs no setup.
    func testPlaylistAlreadyContainingTheItemIsDisabled() {
        launch()
        openPrimaryMovieDetail().openAddToPlaylist()

        let picker = AddToPlaylistScreen(app: app)
        picker.awaitLoaded()

        let alreadyHasIt = picker.playlistRow(UITestFixtureIdentity.playlistID)
        alreadyHasIt.awaitExistence("the playlist that already holds this movie")
        XCTAssertFalse(alreadyHasIt.isEnabled, "A playlist already holding the item must be disabled.")

        // The one that doesn't hold it stays tappable.
        XCTAssertTrue(picker.playlistRow(UITestFixtureIdentity.secondPlaylistID).isEnabled)
    }

    /// The state is live, not just seeded: add to an empty playlist, reopen
    /// the picker, and that row is now the disabled one.
    func testAPlaylistBecomesDisabledAfterAddingToIt() {
        launch()
        let detail = openPrimaryMovieDetail()
        detail.openAddToPlaylist()

        let picker = AddToPlaylistScreen(app: app)
        picker.awaitLoaded()
        picker.playlistRow(UITestFixtureIdentity.secondPlaylistID).tap()
        picker.newPlaylistButton.awaitDisappearance("the Add to Playlist sheet")

        detail.awaitLoaded()
        detail.openAddToPlaylist()
        picker.awaitLoaded()

        XCTAssertFalse(
            picker.playlistRow(UITestFixtureIdentity.secondPlaylistID).isEnabled,
            "A playlist just added to must come back disabled."
        )
    }

    // MARK: - Creating a playlist

    /// Name it, confirm it, and it exists: re-opening the picker lists the
    /// playlist that was just created, which is only possible if the create
    /// actually reached the server.
    func testCreatingAPlaylistAddsTheAssetAndListsItAfterwards() {
        launch()
        let detail = openPrimaryMovieDetail()
        detail.openAddToPlaylist()

        let picker = AddToPlaylistScreen(app: app)
        picker.awaitLoaded()
        picker.createPlaylist(named: "Weeknights")

        picker.newPlaylistButton.awaitDisappearance("the Add to Playlist sheet")
        detail.awaitLoaded()

        detail.openAddToPlaylist()
        picker.awaitLoaded()
        picker.playlistRow("playlist-created-1").awaitExistence("the newly created playlist")
    }

    /// The Create action stays disabled until there's a name to create — an
    /// unnamed playlist is one the server would reject and the user could
    /// never find again.
    func testCreateIsDisabledUntilTheNameIsNonEmpty() {
        launch()
        openPrimaryMovieDetail().openAddToPlaylist()

        let picker = AddToPlaylistScreen(app: app)
        picker.awaitLoaded()
        picker.newPlaylistButton.tap()

        picker.nameField.awaitExistence("the playlist name field")
        XCTAssertFalse(picker.createButton.isEnabled, "Create must be disabled with no name.")

        picker.nameField.tap()
        picker.nameField.typeText("Weeknights")
        XCTAssertTrue(picker.createButton.isEnabled, "Create must enable once a name is typed.")
    }

    /// New playlists start private — Jellyfin's create endpoint defaults
    /// `IsPublic` to *true* server-side, so this toggle starting off is the
    /// visible half of the app always sending it explicitly.
    func testNewPlaylistsDefaultToPrivate() {
        launch()
        openPrimaryMovieDetail().openAddToPlaylist()

        let picker = AddToPlaylistScreen(app: app)
        picker.awaitLoaded()
        picker.newPlaylistButton.tap()

        picker.visibilityToggle.awaitExistence("the visibility toggle")
        XCTAssertEqual(
            picker.visibilityToggle.value as? String, "0",
            "A new playlist must default to private."
        )
    }

    // MARK: - Navigation helpers

    @discardableResult
    private func openPrimaryMovieDetail() -> AssetDetailScreen {
        let home = HomeScreen(app: app)
        home.awaitLoaded()
        home.openItem(UITestFixtureIdentity.primaryMovieID)

        let detail = AssetDetailScreen(app: app)
        detail.awaitLoaded()
        return detail
    }

    @discardableResult
    private func openSeriesDetail() -> AssetDetailScreen {
        let home = HomeScreen(app: app)
        home.awaitLoaded()
        home.openLibrary(UITestFixtureIdentity.showsLibraryID)

        let collection = CollectionScreen(app: app)
        collection.awaitLoaded(UITestFixtureIdentity.seriesID)
        collection.card(UITestFixtureIdentity.seriesID).tap()

        let detail = AssetDetailScreen(app: app)
        detail.awaitLoaded()
        return detail
    }

    /// The stub's id for the `index`-th item added to `secondPlaylist`
    /// during this run — what `PlaylistItemList` keys its rows on.
    private func addedEntry(index: Int) -> String {
        UITestFixtureIdentity.addedPlaylistEntryID(
            playlistID: UITestFixtureIdentity.secondPlaylistID, index: index
        )
    }

    /// Unwinds the Home tab's navigation stack back to Home itself.
    ///
    /// Uses the navigation bar's own back button, one push at a time. Two
    /// tidier-looking alternatives were tried first and both failed live:
    /// tapping the already-selected Home tab does *not* pop this app's stack
    /// to its root, and waiting on Home's own elements can't detect the
    /// difference either way, because the root stays mounted underneath a
    /// pushed page — `heroCarousel` and `libraryRail` exist the whole time,
    /// and the swipe in `openLibrary` then fails with "visible frame is
    /// empty".
    ///
    /// Unwinds the Home tab's navigation stack back to a usable Home screen.
    ///
    /// Two things here are the result of measuring rather than guessing, and
    /// both are why this is the only back-navigation in the suite:
    ///
    /// - The stack is popped by UIKit's own back button, addressed by its
    ///   `BackButton` identifier. Tapping the already-selected Home tab does
    ///   *not* pop this app's stack, and Home has no toolbar buttons of its
    ///   own at the root, so its absence is what "fully unwound" means.
    /// - Home restores its **scroll position** on the way back, and
    ///   `openItem` will have auto-scrolled down to reach a rail tile — so
    ///   the library rail typically returns at a negative `y`, still
    ///   `exists` but with an empty visible frame. `openLibrary`'s swipe
    ///   then fails with "visible frame is empty". Scrolling back to the top
    ///   first is what makes it reachable.
    ///
    /// Both loops are bounded rather than `while`: a gesture that stops
    /// making progress should surface as a timeout on the caller's next
    /// assertion, not spin.
    private func popToHome(file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<3 {
            let back = app.navigationBars.buttons["BackButton"]
            guard back.exists else { break }
            back.tap()
        }
        HomeScreen(app: app).awaitLoaded(file: file, line: line)

        let rail = app.descendants(matching: .any)[A11yID.Home.libraryRail]
        for _ in 0..<4 where !rail.isHittable {
            app.swipeDown()
        }
    }

    /// Opens `secondPlaylist`, which ships empty — so anything listed there
    /// arrived via an add this test performed.
    @discardableResult
    private func openSecondPlaylistDetail(
        file: StaticString = #filePath, line: UInt = #line
    ) -> AssetDetailScreen {
        popToHome(file: file, line: line)

        let home = HomeScreen(app: app)
        home.openLibrary(UITestFixtureIdentity.playlistsLibraryID, file: file, line: line)

        let collection = CollectionScreen(app: app)
        collection.awaitLoaded(UITestFixtureIdentity.secondPlaylistID, file: file, line: line)
        collection.card(UITestFixtureIdentity.secondPlaylistID).tap()

        // `PlaylistItemList` lives on the same screen object as the rest of
        // the detail page — see `AssetDetailScreen.playlistRow(_:)`.
        return AssetDetailScreen(app: app)
    }
}
