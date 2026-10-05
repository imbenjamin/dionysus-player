import XCTest

/// A show's page: Play names the episode it starts, season tabs switch the
/// episode rail, and an episode tile plays.
final class ShowDetailJourneyTests: TVUITestCase {
    private func episode(_ app: XCUIApplication, season: Int, _ number: Int) -> XCUIElement {
        app.buttons[A11yID.TV.Detail.episode(UITestFixtureIdentity.episodeID(season: season, episode: number))]
    }

    /// Opens the fixture series from the TV Shows library.
    private func openSeries(_ app: XCUIApplication, waitsForPlay: Bool = true) {
        openRailFromHome(app)
        pressDown(until: app.buttons[A11yID.TV.Sidebar.library(UITestFixtureIdentity.showsLibraryID)])
        press(.select)
        let tile = app.buttons[A11yID.TV.Library.tile(UITestFixtureIdentity.seriesID)]
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFocus(tile))
        if waitsForPlay { openDetailFromFocusedTile(app) } else { press(.select) }
    }

    func test_show_namesTheEpisodeOnPlay_andListsItsSeasonsEpisodes() {
        let app = launchAtHome()
        openSeries(app)
        let play = app.buttons[A11yID.TV.Detail.play]
        // The stub's Next Up for the series is S1:E2.
        XCTAssertTrue(poll(timeout: 10) { play.label.contains("S1:E2") }, "Play names the episode it starts")
        XCTAssertTrue(play.hasFocus, "Focus stays on Play while its episode is resolved")
        XCTAssertTrue(episode(app, season: 1, 1).waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.matching(identifier: A11yID.TV.Detail.badge).firstMatch.waitForExistence(timeout: 10), "The episode's format badges show, as on a movie's page")
        let subject = app.staticTexts[A11yID.TV.Detail.detailsSubject]
        XCTAssertTrue(poll(timeout: 10) { subject.exists && subject.label.contains("S1:E2") }, "Details describes the episode Play starts")
    }

    func test_seasonTab_switchesTheEpisodeRail() {
        let app = launchAtHome()
        openSeries(app)
        XCTAssertTrue(episode(app, season: 1, 1).waitForExistence(timeout: 10))
        let seasonTwo = app.buttons[A11yID.TV.Detail.season("season-2")]
        let seasonOne = app.buttons[A11yID.TV.Detail.season("season-1")]
        press(.down)
        XCTAssertTrue(waitForFocus(seasonOne), "Down from the actions lands on the season on show, not the tab nearest Play")
        press(.right)
        XCTAssertTrue(waitForFocus(seasonTwo))
        XCTAssertTrue(episode(app, season: 2, 1).waitForExistence(timeout: 10), "Focusing a tab shows its season, no Select needed")
        XCTAssertTrue(poll(timeout: 5) { !self.episode(app, season: 1, 1).exists })
        press(.down)
        XCTAssertTrue(waitForFocus(episode(app, season: 2, 1)))
        press(.up)
        XCTAssertTrue(waitForFocus(seasonTwo), "Up from the episodes returns to their season's tab, and the season stays")
        XCTAssertTrue(episode(app, season: 2, 1).exists)
    }

    /// Below the episodes a show has the movie page's rails.
    func test_down_fromTheEpisodes_reachesMoreLikeThis() {
        let app = launchAtHome()
        openSeries(app)
        XCTAssertTrue(episode(app, season: 1, 1).waitForExistence(timeout: 10))
        let similar = app.buttons.matching(NSPredicate(format: "hasFocus == true AND identifier BEGINSWITH %@", "tv.detail.similar.")).firstMatch
        for _ in 0..<5 where !similar.exists { press(.down) }
        XCTAssertTrue(similar.waitForExistence(timeout: 5))
        press(.select)
        XCTAssertTrue(poll(timeout: 10) { !similar.exists && app.buttons[A11yID.TV.Detail.play].hasFocus }, "A More Like This tile opens its own page")
        press(.menu)
        XCTAssertTrue(similar.waitForExistence(timeout: 5), "Menu returns to the tile on the show's page")

        // Details is the last row, as on a movie's page.
        press(.down)
        let details = app.buttons[A11yID.TV.Detail.details]
        XCTAssertTrue(waitForFocus(details))
        // Walking through the rail chooses nothing: Details is still the
        // episode Play starts.
        XCTAssertTrue(app.staticTexts[A11yID.TV.Detail.detailsSubject].label.contains("S1:E2"))
        press(.select)
        let full = app.staticTexts[A11yID.TV.Detail.fullDetailsTitle]
        XCTAssertTrue(full.waitForExistence(timeout: 5), "Select on Details opens the full list")
        press(.menu)
        XCTAssertTrue(poll(timeout: 5) { !full.exists })
    }

    /// An episode tile turns the page to that episode, in place, rather
    /// than playing it: focus goes to Play, which is now that episode.
    func test_episodeTile_turnsThePageToThatEpisode_withFocusOnPlay() {
        let app = launchAtHome()
        openSeries(app)
        let third = episode(app, season: 1, 3)
        XCTAssertTrue(third.waitForExistence(timeout: 10))
        let play = app.buttons[A11yID.TV.Detail.play]
        // Play, not the title: the header gains the episode's name, which
        // moves the title up.
        let startY = play.frame.minY
        press(.down, times: 2)
        XCTAssertTrue(waitForFocus(episode(app, season: 1, 1)), "Down from the tabs lands on the first episode")
        press(.right, times: 2)
        XCTAssertTrue(waitForFocus(third))
        press(.select)
        XCTAssertTrue(waitForFocus(play), "Focus goes to Play")
        XCTAssertFalse(app.staticTexts[A11yID.TV.Player.elapsed].exists, "The tile didn't play")
        XCTAssertTrue(poll(timeout: 5) { play.label.contains("S1:E3") }, "Play is the episode chosen, not the show's next one")
        XCTAssertTrue(poll(timeout: 5) { abs(play.frame.minY - startY) < 2 }, "The page is back at its top")
        let subject = app.staticTexts[A11yID.TV.Detail.detailsSubject]
        XCTAssertTrue(subject.label.contains("S1:E3"), "Details describes the episode chosen")

        press(.select)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Player.elapsed].waitForExistence(timeout: 10))
        press(.menu)
        XCTAssertTrue(poll(timeout: 5) { !app.staticTexts[A11yID.TV.Player.elapsed].exists })
        XCTAssertTrue(play.label.contains("S1:E3"), "Back on the same episode's page")
    }

    /// A Continue Watching episode tile opens its show's page on that
    /// episode, as iOS does.
    func test_episodeTileOnHome_opensItsShowPage_onThatEpisode() {
        let app = launchAtHomeTile()
        let episodeTile = app.buttons[A11yID.TV.Main.tile(UITestFixtureIdentity.episodeID(season: 1, episode: 1))]
        press(.right)
        XCTAssertTrue(waitForFocus(episodeTile))
        let play = openDetailFromFocusedTile(app)
        XCTAssertTrue(play.label.contains("S1:E1"), "Play is the episode the tile was for")
        XCTAssertTrue(episode(app, season: 1, 1).waitForExistence(timeout: 10))
        press(.menu)
        XCTAssertTrue(waitForFocus(episodeTile))
    }

    /// A show whose seasons hold no episodes: no Play button, a message in
    /// place of the rail, and focus somewhere Menu can pop from.
    func test_showWithoutEpisodes_hasNoPlay_andMenuPops() {
        let app = launchAtHome(scenario: "showWithoutEpisodes")
        openSeries(app, waitsForPlay: false)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Detail.noEpisodes].waitForExistence(timeout: 10))
        XCTAssertTrue(poll(timeout: 5) { !app.buttons[A11yID.TV.Detail.play].exists }, "Nothing to play, so no Play button")
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Detail.watched]))
        press(.menu)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Library.tile(UITestFixtureIdentity.seriesID)]))
    }
}
