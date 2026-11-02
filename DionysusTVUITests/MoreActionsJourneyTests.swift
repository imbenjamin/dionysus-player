import XCTest

/// A detail page's More Actions (after Favorite): a system menu with iOS's
/// Add to Playlist and Delete, each opening a full-screen page Menu closes
/// onto the button.
///
/// A SwiftUI `Menu` reports focus on an unnamed child, not on itself, and a
/// menu row's focus on the `Cell` around it, so focus is read through
/// `isFocused`. Rows aren't buttons, so they're found among any elements. A
/// submenu's rows lose their identifiers on tvOS 27 (on the Button and on its
/// Label alike; tvOS 26 keeps them), so `submenuRow` takes the identifier
/// where it's there and the label otherwise: the stub's titles, never
/// localized copy.
final class MoreActionsJourneyTests: TVUITestCase {
    private let movieID = UITestFixtureIdentity.partWatchedMovieID
    private let seriesID = UITestFixtureIdentity.seriesID

    // MARK: - Helpers

    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id]
    }

    private func isFocused(_ element: XCUIElement) -> Bool {
        guard element.exists else { return false }
        if element.hasFocus || element.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).count > 0 {
            return true
        }
        let cell = XCUIApplication().cells.matching(NSPredicate(format: "hasFocus == true")).firstMatch
        return cell.exists && cell.frame.insetBy(dx: -4, dy: -4).contains(element.frame)
    }

    /// A submenu's row: its identifier, or on tvOS 27 the start of its label
    /// (the show's or season's name, or an episode's "S1:E1").
    /// `id` is the start of the target's id, so "episode-" finds any episode.
    private func submenuRow(_ app: XCUIApplication, _ row: (id: String, label: String)) -> XCUIElement {
        app.cells.otherElements.matching(NSPredicate(
            format: "identifier CONTAINS %@ OR (identifier == '' AND label BEGINSWITH %@)",
            "." + row.id, row.label
        )).firstMatch
    }

    private func waitFocused(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        poll(timeout: timeout) { self.isFocused(element) }
    }

    private func pressDown(toFocus element: XCUIElement, max: Int = 8) {
        for _ in 0..<max where !isFocused(element) {
            press(.down)
            _ = poll(timeout: 1) { self.isFocused(element) }
        }
        XCTAssertTrue(waitFocused(element))
    }

    @discardableResult
    private func focusMore(_ app: XCUIApplication) -> XCUIElement {
        let more = any(app, A11yID.TV.Detail.more)
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        for _ in 0..<6 where !isFocused(more) {
            press(.right)
            _ = poll(timeout: 1) { self.isFocused(more) }
        }
        XCTAssertTrue(waitFocused(more), "Right along the actions reaches More")
        return more
    }

    /// Home's first Continue Watching tile (a part-watched movie), its page,
    /// and More's menu open on its first row.
    private func openMovieMenu(_ app: XCUIApplication) {
        openDetailFromFocusedTile(app)
        focusMore(app)
        press(.select)
        let add = any(app, A11yID.TV.Actions.addToPlaylist(movieID))
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        XCTAssertTrue(waitFocused(add), "The menu opens on Add to Playlist")
    }

    /// From the open menu, Add to Playlist's picker.
    private func openMoviePicker(_ app: XCUIApplication) {
        openMovieMenu(app)
        press(.select)
        XCTAssertTrue(app.buttons[A11yID.TV.Actions.newPlaylist].waitForExistence(timeout: 10))
    }

    private func toastMessage(_ app: XCUIApplication) -> String? {
        let toast = any(app, A11yID.Toast.message)
        return toast.waitForExistence(timeout: 10) ? toast.label : nil
    }

    /// Down to a Delete row, Select, then the question's Delete (it opens on
    /// Cancel).
    private func confirmDelete(_ app: XCUIApplication, row: XCUIElement) {
        pressDown(toFocus: row)
        press(.select)
        let confirm = app.buttons[A11yID.TV.Actions.deleteConfirm]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.confirmationCancel]), "The question opens on Cancel")
        press(.up)
        XCTAssertTrue(waitForFocus(confirm))
        press(.select)
    }

    // MARK: - The button and its menu

    func test_more_sitsAfterFavorite_andOpensItsMenu() {
        let app = launchAtHomeTile()
        openDetailFromFocusedTile(app)
        let more = focusMore(app)
        press(.left)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Detail.favorite]), "More sits right of Favorite")
        press(.right)
        XCTAssertTrue(waitFocused(more))

        press(.select)
        let add = any(app, A11yID.TV.Actions.addToPlaylist(movieID))
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        XCTAssertTrue(any(app, A11yID.TV.Actions.delete(movieID)).exists, "The fixture user may delete")

        press(.menu)
        XCTAssertTrue(waitFocused(more), "Menu closes the menu onto More")
        XCTAssertTrue(poll(timeout: 5) { !add.exists })
    }

    func test_more_withoutDeletePermission_offersOnlyAddToPlaylist() {
        let app = launchAtHomeTile(scenario: "noDeletePermission")
        openMovieMenu(app)
        XCTAssertFalse(any(app, A11yID.TV.Actions.delete(movieID)).exists, "No Delete without the server's permission")
    }

    // MARK: - Add to Playlist

    /// One movie is one item: added at once, no question, with a toast naming
    /// the playlist. Opened again, that playlist is ticked and dimmed, which
    /// is the server's own record of the add (the stub replays it).
    func test_addMovieToPlaylist_addsAtOnce_thenListsItAsAdded() {
        let app = launchAtHomeTile()
        openMoviePicker(app)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Actions.newPlaylist]), "The picker opens on New Playlist")
        let row = app.buttons[A11yID.TV.Actions.playlistRow(UITestFixtureIdentity.secondPlaylistID)]
        XCTAssertTrue(row.exists)
        XCTAssertFalse(app.buttons[A11yID.TV.Actions.playlistRow(UITestFixtureIdentity.readOnlyPlaylistID)].exists, "Only playlists this user may edit")
        pressDown(until: row)
        press(.select)

        // The toast first: it's up for 2.5 s.
        let message = toastMessage(app)
        XCTAssertTrue(message?.contains(UITestFixtureIdentity.secondPlaylistName) == true, "The toast names the playlist. Was: \(message ?? "nil")")
        XCTAssertFalse(app.buttons[A11yID.TV.Actions.addConfirm].exists, "A single movie doesn't ask")
        XCTAssertTrue(waitFocused(any(app, A11yID.TV.Detail.more)), "The page closes onto More")

        press(.select)
        XCTAssertTrue(waitFocused(any(app, A11yID.TV.Actions.addToPlaylist(movieID))))
        press(.select)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertFalse(row.isEnabled, "A playlist already holding the movie is dimmed")
        XCTAssertEqual(row.value as? String, "Already added")
    }

    func test_newPlaylist_createsAfterConfirming() {
        let app = launchAtHomeTile()
        openMoviePicker(app)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Actions.newPlaylist]))
        press(.select)

        let field = app.textFields[A11yID.TV.Actions.nameField]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForFocus(field))
        press(.select)
        field.typeText("Weeknights")
        press(.menu)
        let create = app.buttons[A11yID.TV.Actions.create]
        pressDown(until: create)
        press(.select)

        let confirm = app.buttons[A11yID.TV.Actions.createConfirm]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.confirmationCancel]), "The question opens on Cancel")
        press(.up)
        XCTAssertTrue(waitForFocus(confirm))
        press(.select)

        let message = toastMessage(app)
        XCTAssertTrue(message?.contains("Weeknights") == true, "The toast names the new playlist. Was: \(message ?? "nil")")
        XCTAssertTrue(waitFocused(any(app, A11yID.TV.Detail.more)))
    }

    func test_picker_menuClosesItOntoMore() {
        let app = launchAtHomeTile()
        openMoviePicker(app)
        press(.menu)
        XCTAssertTrue(waitFocused(any(app, A11yID.TV.Detail.more)))
        XCTAssertFalse(app.buttons[A11yID.TV.Actions.newPlaylist].exists)
    }

    // MARK: - Delete

    func test_deleteMovie_questionOpensOnCancel_andMenuCancels() {
        let app = launchAtHomeTile()
        openMovieMenu(app)
        pressDown(toFocus: any(app, A11yID.TV.Actions.delete(movieID)))
        press(.select)

        XCTAssertTrue(app.buttons[A11yID.TV.Actions.deleteConfirm].waitForExistence(timeout: 5))
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.confirmationCancel]), "A stray Select changes nothing")
        press(.menu)
        XCTAssertTrue(waitFocused(any(app, A11yID.TV.Detail.more)), "Menu closes the question onto More")
        XCTAssertTrue(app.buttons[A11yID.TV.Detail.play].exists, "Nothing was deleted")
    }

    /// Deleting the title a page shows pops it (`DeletionOutcome.popOneLevel`),
    /// and Home, back on show, no longer lists it.
    func test_deleteMovie_popsBackToHome_withoutIt() {
        let app = launchAtHomeTile()
        openMovieMenu(app)
        confirmDelete(app, row: any(app, A11yID.TV.Actions.delete(movieID)))

        XCTAssertTrue(poll(timeout: 10) { !self.any(app, A11yID.TV.Detail.more).exists }, "The page pops")
        XCTAssertTrue(app.buttons[A11yID.TV.Main.heroPlay].waitForExistence(timeout: 10), "Back on Home")
        XCTAssertTrue(poll(timeout: 10) { !app.buttons[A11yID.TV.Main.tile(self.movieID)].exists }, "Home no longer lists the deleted movie")
    }

    // MARK: - A show's page

    private func episodeTile(_ app: XCUIApplication, season: Int, _ number: Int) -> XCUIElement {
        app.buttons[A11yID.TV.Detail.episode(UITestFixtureIdentity.episodeID(season: season, episode: number))]
    }

    /// The fixture series from the TV Shows library, on its Play.
    private func openSeries(_ app: XCUIApplication) {
        openRailFromHome(app)
        pressDown(until: app.buttons[A11yID.TV.Sidebar.library(UITestFixtureIdentity.showsLibraryID)])
        press(.select)
        let tile = app.buttons[A11yID.TV.Library.tile(seriesID)]
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFocus(tile))
        openDetailFromFocusedTile(app)
        XCTAssertTrue(episodeTile(app, season: 1, 1).waitForExistence(timeout: 10))
    }

    /// Down to the first season's first episode, and Select: the page turns
    /// to it in place, with focus on Play.
    private func chooseFirstEpisode(_ app: XCUIApplication) {
        pressDown(until: episodeTile(app, season: 1, 1))
        press(.select)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Detail.play]))
    }

    private var seriesRow: (id: String, label: String) { (seriesID, UITestFixtureIdentity.seriesName) }
    private let seasonRow = (id: "season-1", label: "Season 1")
    private let episodeRow = (id: UITestFixtureIdentity.episodeID(season: 1, episode: 1), label: "S1:E1")
    /// The stub's Next Up: the episode Play starts on the series.
    private let nextUpRow = (id: UITestFixtureIdentity.episodeID(season: 1, episode: 2), label: "S1:E2")

    /// More's menu, then its Add to Playlist submenu (several targets).
    private func openAddSubmenu(_ app: XCUIApplication) {
        focusMore(app)
        press(.select)
        let submenu = any(app, A11yID.TV.Actions.addSubmenu)
        XCTAssertTrue(submenu.waitForExistence(timeout: 5))
        XCTAssertTrue(waitFocused(submenu), "The menu opens on Add to Playlist")
        press(.select)
        XCTAssertTrue(submenuRow(app, seriesRow).waitForExistence(timeout: 5))
    }

    /// More's menu, then its Delete submenu (below Add to Playlist).
    private func openDeleteSubmenu(_ app: XCUIApplication) {
        focusMore(app)
        press(.select)
        let submenu = any(app, A11yID.TV.Actions.deleteSubmenu)
        XCTAssertTrue(submenu.waitForExistence(timeout: 5))
        pressDown(toFocus: submenu)
        press(.select)
        XCTAssertTrue(submenuRow(app, seriesRow).waitForExistence(timeout: 5))
    }

    private func assertInOrder(_ elements: [XCUIElement], _ message: String) {
        XCTAssertTrue(elements.allSatisfy(\.exists), message)
        let ys = elements.map(\.frame.minY)
        XCTAssertEqual(ys, ys.sorted(), "Most specific last: \(message)")
    }

    /// On the series, the episode Play starts is offered too (Benjamin,
    /// 2026-10-26), in both menus: Delete gates it on its `CanDelete`, which
    /// the stub's Next Up serves only when asked for.
    func test_more_onTheSeries_offersTheEpisodePlayStarts() {
        let app = launchAtHome()
        openSeries(app)
        let rows = [seriesRow, seasonRow, nextUpRow]

        openAddSubmenu(app)
        assertInOrder(rows.map { submenuRow(app, $0) }, "Add: show, season, Play's episode")
        press(.menu)
        press(.menu)
        XCTAssertTrue(waitFocused(any(app, A11yID.TV.Detail.more)))

        openDeleteSubmenu(app)
        assertInOrder(rows.map { submenuRow(app, $0) }, "Delete: show, season, Play's episode")
    }

    /// Deleting it leaves the page on the series, and Play moves on.
    func test_deleteTheEpisodePlayStarts_staysOnTheShow() {
        let app = launchAtHome()
        openSeries(app)
        openDeleteSubmenu(app)
        confirmDelete(app, row: submenuRow(app, nextUpRow))

        XCTAssertTrue(poll(timeout: 10) { !self.episodeTile(app, season: 1, 2).exists }, "The episode leaves the rail")
        XCTAssertTrue(episodeTile(app, season: 1, 1).exists, "The rest of the season stays")
        XCTAssertTrue(app.buttons[A11yID.TV.Detail.play].exists, "Still the show's page")
    }

    func test_more_onAnEpisode_offersShowSeasonAndEpisode() {
        let app = launchAtHome()
        openSeries(app)
        chooseFirstEpisode(app)
        let rows = [seriesRow, seasonRow, episodeRow]

        openAddSubmenu(app)
        assertInOrder(rows.map { submenuRow(app, $0) }, "Add: show, season, episode")
        press(.menu)
        press(.menu)
        XCTAssertTrue(waitFocused(any(app, A11yID.TV.Detail.more)))

        openDeleteSubmenu(app)
        assertInOrder(rows.map { submenuRow(app, $0) }, "Delete: show, season, episode")
    }

    /// Review Focus 1: an episode chosen in place isn't the page, so the page
    /// stays, back on the series, with focus on More.
    func test_deleteEpisode_pickedInPlace_staysOnTheShow() {
        let app = launchAtHome()
        openSeries(app)
        chooseFirstEpisode(app)
        openDeleteSubmenu(app)
        confirmDelete(app, row: submenuRow(app, episodeRow))

        XCTAssertTrue(poll(timeout: 10) { !self.episodeTile(app, season: 1, 1).exists }, "The episode leaves the rail")
        XCTAssertTrue(episodeTile(app, season: 1, 2).exists, "The rest of the season stays")
        XCTAssertTrue(waitFocused(any(app, A11yID.TV.Detail.more)), "Focus stays on More")
        XCTAssertTrue(app.buttons[A11yID.TV.Detail.play].exists, "Still the show's page")
    }

    /// Review Focus 2: the tabs move to a season that's left.
    func test_deleteSeason_movesTheTabsToARemainingSeason() {
        let app = launchAtHome()
        openSeries(app)
        openDeleteSubmenu(app)
        confirmDelete(app, row: submenuRow(app, seasonRow))

        XCTAssertTrue(episodeTile(app, season: 2, 1).waitForExistence(timeout: 10), "The remaining season's episodes show")
        XCTAssertFalse(episodeTile(app, season: 1, 1).exists)
        XCTAssertFalse(app.buttons[A11yID.TV.Detail.season("season-1")].exists)
        XCTAssertTrue(app.buttons[A11yID.TV.Detail.play].exists, "The show is still there")
    }

    /// Delete's submenu, open on a page back on the series: the episode it
    /// offers is Play's (`playsEpisode`, when one is left), never the one
    /// deleted.
    private func assertDeleteOffersPlaysEpisode(_ app: XCUIApplication, playsEpisode: (id: String, label: String)?) {
        XCTAssertTrue(waitFocused(any(app, A11yID.TV.Detail.more), timeout: 10), "Focus back on More")
        openDeleteSubmenu(app)
        XCTAssertFalse(submenuRow(app, episodeRow).exists, "The page is back on the series")
        if let playsEpisode {
            XCTAssertTrue(submenuRow(app, playsEpisode).exists, "Play's episode is offered")
        }
        press(.menu)
        press(.menu)
    }

    /// The chosen episode deleted while another season's tab is on show: the
    /// page still gives itself back to the series (review, Important 2).
    func test_deleteChosenEpisode_fromAnotherSeasonsTab_givesThePageBackToTheSeries() {
        let app = launchAtHome()
        openSeries(app)
        chooseFirstEpisode(app)
        let season2 = app.buttons[A11yID.TV.Detail.season("season-2")]
        pressDown(until: app.buttons[A11yID.TV.Detail.season("season-1")])
        press(.right)
        XCTAssertTrue(waitForFocus(season2))
        XCTAssertTrue(episodeTile(app, season: 2, 1).waitForExistence(timeout: 10))
        press(.up)

        openDeleteSubmenu(app)
        confirmDelete(app, row: submenuRow(app, episodeRow))
        assertDeleteOffersPlaysEpisode(app, playsEpisode: nextUpRow)
    }

    /// The chosen episode's whole season deleted (review, Important 2).
    func test_deleteChosenEpisodesSeason_givesThePageBackToTheSeries() {
        let app = launchAtHome()
        openSeries(app)
        chooseFirstEpisode(app)
        openDeleteSubmenu(app)
        confirmDelete(app, row: submenuRow(app, seasonRow))
        XCTAssertTrue(episodeTile(app, season: 2, 1).waitForExistence(timeout: 10))
        // Play's episode went with the season; which one replaces it is
        // `resolveShowPlaybackEpisode`'s business.
        assertDeleteOffersPlaysEpisode(app, playsEpisode: nil)
    }

    /// A season with no folder (Benjamin's library): offered once its
    /// episodes are known to be deletable, and deleted episode by episode.
    func test_folderlessSeason_isOffered_andDeleted() {
        let app = launchAtHome(scenario: "folderlessSeasons")
        openSeries(app)
        openDeleteSubmenu(app)
        let season = submenuRow(app, seasonRow)
        XCTAssertTrue(season.waitForExistence(timeout: 5), "The folderless season is offered")
        confirmDelete(app, row: season)

        XCTAssertTrue(episodeTile(app, season: 2, 1).waitForExistence(timeout: 15), "The tabs move to what's left")
        XCTAssertFalse(app.buttons[A11yID.TV.Detail.season("season-1")].exists)
    }

    func test_addSeasonToPlaylist_asksFirst() {
        let app = launchAtHome()
        openSeries(app)
        openAddSubmenu(app)
        pressDown(toFocus: submenuRow(app, seasonRow))
        press(.select)
        let row = app.buttons[A11yID.TV.Actions.playlistRow(UITestFixtureIdentity.secondPlaylistID)]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        pressDown(until: row)
        press(.select)

        let confirm = app.buttons[A11yID.TV.Actions.addConfirm]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "A whole season asks first")
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.confirmationCancel]))
        XCTAssertEqual(confirm.label, "Add 3 Episodes")
        press(.up)
        XCTAssertTrue(waitForFocus(confirm))
        press(.select)
        let message = toastMessage(app)
        XCTAssertTrue(message?.contains("3 episodes") == true, "Was: \(message ?? "nil")")
    }
}
