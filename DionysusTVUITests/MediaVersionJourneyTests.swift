import XCTest

/// Choosing a version to play on the Apple TV (#289): "Choose a Version",
/// a page of its own (`TVVersionPickerPage`). Whether it asks follows the
/// title, not the button (Benjamin, 2026-11-13): without a resume point Play
/// asks, the remembered version marked; with one, Resume and Restart play the
/// remembered version, asking only when nothing remembered is listed. The
/// Home hero and playlist rows ask too (D1); auto-advance asks over the
/// player only when it can't carry the choice over (D2); a plain play link
/// never asks, the Top Shelf's Play does (D3).
///
/// The stub's `multipleVersions` scenario: movie-01 unwatched in 4K HDR10 and
/// 1080p, movie-02 part-watched as Original and Director's Cut, S2:E1 in 4K
/// and 1080p, S2:E2 as Original and Extended Edition. What played is read from
/// Playback Stats' Version row (`A11yID.PlaybackStats.versionValue`).
final class MediaVersionJourneyTests: TVUITestCase {
    private let quietAscent = UITestFixtureIdentity.primaryMovieID // movie-01, unwatched
    private let signalFire = UITestFixtureIdentity.partWatchedMovieID // movie-02, part-watched

    private func link(_ path: String) -> URL { URL(string: "dionysus://" + path)! }

    private func option(_ app: XCUIApplication, _ versionID: String) -> XCUIElement {
        app.buttons[A11yID.TV.versionOption(versionID)]
    }

    private func picker(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts[A11yID.TV.versionPickerTitle]
    }

    /// Signed in on Home, the transport kept up so the Stats icon is reachable.
    /// `extraArguments`' `-UITestEarlyCreditsItem <id>` gives that item end
    /// credits from 0:05, so its Next Up advance comes about 15 s in.
    private func launchAtHomeWithVersions(extraArguments: [String] = []) -> XCUIApplication {
        let app = launch(
            scenario: "multipleVersions", seedSession: true,
            extraArguments: ["-UITestDisableControlAutoHide", "YES", "-showPlaybackStatsButtonEnabled", "YES"] + extraArguments
        )
        XCTAssertTrue(app.buttons[A11yID.TV.Main.heroPlay].waitForExistence(timeout: 10))
        return app
    }

    /// `itemID`'s page, by its link, with focus on Play.
    @discardableResult
    private func openPage(_ itemID: String, _ app: XCUIApplication) -> XCUIElement {
        app.open(link("item/\(itemID)"))
        let play = app.buttons[A11yID.TV.Detail.play]
        XCTAssertTrue(waitForFocus(play, timeout: 10), "\(itemID)'s page, Play focused")
        return play
    }

    /// Moves focus down the question to `versionID` and chooses it.
    private func choose(_ versionID: String, _ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let button = option(app, versionID)
        XCTAssertTrue(button.waitForExistence(timeout: 10), "The question offers \(versionID)", file: file, line: line)
        XCTAssertTrue(moveFocus(to: button, pressing: .down, limit: 4), "Focus reaches \(versionID)", file: file, line: line)
        press(.select)
    }

    /// Opens Playback Stats and checks the Version row names `label`.
    private func assertPlaying(_ label: String, _ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.staticTexts[A11yID.TV.Player.elapsed].waitForExistence(timeout: 10), "The player", file: file, line: line)
        XCTAssertTrue(waitForPlayerFocus(app, "scrubber"), file: file, line: line)
        press(.up)
        for _ in 0..<6 where playerFocus(app) != "icon.stats" { press(.right) }
        XCTAssertTrue(waitForPlayerFocus(app, "icon.stats"), file: file, line: line)
        press(.select)
        let version = app.descendants(matching: .any)[A11yID.PlaybackStats.versionValue]
        XCTAssertTrue(version.waitForExistence(timeout: 5), "Playback Stats' Version row", file: file, line: line)
        XCTAssertTrue(poll(timeout: 5) { version.value as? String == label },
                      "Version read \(String(describing: version.value))", file: file, line: line)
    }

    /// Proves the question doesn't come: the player is reached with no
    /// version page on the way.
    private func assertPlaysWithoutAsking(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let elapsed = app.staticTexts[A11yID.TV.Player.elapsed]
        let deadline = Date().addingTimeInterval(10)
        while !elapsed.exists, Date() < deadline {
            XCTAssertFalse(picker(app).exists, "No version question on the way to the player", file: file, line: line)
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(elapsed.exists, "The player", file: file, line: line)
    }

    // MARK: - Starting a title

    /// Play on an unwatched title with two versions asks, focus on the first;
    /// the chosen version plays.
    func test_play_asks_andPlaysTheChosenVersion() {
        let app = launchAtHomeWithVersions()
        openPage(quietAscent, app)
        press(.select)
        XCTAssertTrue(picker(app).waitForExistence(timeout: 10), "Choose a Version")
        XCTAssertTrue(waitForFocus(option(app, "\(quietAscent)-4k")), "Focus starts on the first version")
        choose("\(quietAscent)-1080p", app)
        assertPlaying("1080p", app)
    }

    /// A part-watched title with nothing remembered asks on Resume; once
    /// answered, Resume plays that version without asking.
    func test_resume_doesNotAsk() {
        let app = launchAtHomeWithVersions()
        openPage(signalFire, app)
        press(.select)
        choose("\(signalFire)-directors-cut", app)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Player.elapsed].waitForExistence(timeout: 10))
        leavePlayer(app)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Detail.play]), "Back on the page, Play focused")
        press(.select)
        assertPlaysWithoutAsking(app)
        assertPlaying("Director's Cut", app)
    }

    /// Menu on the question plays nothing and gives focus back to Play.
    func test_menu_onTheQuestion_playsNothing_andFocusReturnsToPlay() {
        let app = launchAtHomeWithVersions()
        let play = openPage(quietAscent, app)
        press(.select)
        XCTAssertTrue(waitForFocus(option(app, "\(quietAscent)-4k"), timeout: 10))
        press(.menu)
        XCTAssertTrue(poll(timeout: 5) { !self.picker(app).exists }, "The question closes")
        XCTAssertTrue(waitForFocus(play), "Focus is back on Play")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertFalse(app.staticTexts[A11yID.TV.Player.elapsed].exists, "Nothing plays")
        // And a fresh press asks again.
        press(.select)
        XCTAssertTrue(picker(app).waitForExistence(timeout: 10), "Play asks again")
    }

    /// The second Play marks the version chosen first "(Last Played)" and
    /// starts on it.
    func test_play_again_startsOnTheLastPlayedVersion() {
        let app = launchAtHomeWithVersions()
        openPage(quietAscent, app)
        press(.select)
        choose("\(quietAscent)-1080p", app)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Player.elapsed].waitForExistence(timeout: 10))
        leavePlayer(app)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Detail.play]))
        press(.select)
        XCTAssertTrue(waitForFocus(option(app, "\(quietAscent)-1080p"), timeout: 10), "Focus starts on the last played")
    }

    /// The hero's Play asks as a page's does (D1). The stub's hero is the
    /// show, whose Play is S1:E1 (part-watched, nothing remembered).
    func test_homeHeroPlay_multiVersion_asks() {
        let app = launchAtHomeWithVersions()
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Main.heroPlay], timeout: 10))
        press(.select)
        XCTAssertTrue(picker(app).waitForExistence(timeout: 10), "Choose a Version")
        press(.select)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Player.elapsed].waitForExistence(timeout: 10), "The choice plays")
    }

    /// A playlist row's Play asks too (D1): the playlist's first member is
    /// movie-01, unwatched, in 4K HDR10 and 1080p.
    func test_playlistRowPlay_multiVersionMember_asks() {
        let app = launchAtHomeWithVersions()
        openPage(UITestFixtureIdentity.playlistID, app)
        press(.down)
        let row = app.buttons[A11yID.TV.Detail.member("playlist-entry-1")]
        XCTAssertTrue(waitForFocus(row), "The playlist's first row")
        press(.select)
        XCTAssertTrue(picker(app).waitForExistence(timeout: 10), "Choose a Version")
        XCTAssertTrue(waitForFocus(option(app, "\(quietAscent)-4k")), "Focus starts on the first version")
        choose("\(quietAscent)-1080p", app)
        assertPlaying("1080p", app)
    }

    // MARK: - Auto-advance (D2)

    /// S2:E1 in 1080p, its credits from 0:05, so Next Up advances about 15 s
    /// in: S2:E2 has no 1080p (Original and Extended Edition), so the advance
    /// asks over the player. Menu closes the player.
    func test_autoAdvance_noMatchingVersion_asksOverThePlayer() {
        let episodeOne = UITestFixtureIdentity.episodeID(season: 2, episode: 1)
        let episodeTwo = UITestFixtureIdentity.episodeID(season: 2, episode: 2)
        let app = launchAtHomeWithVersions(extraArguments: ["-UITestEarlyCreditsItem", episodeOne])
        app.open(link("play/\(episodeOne)?source=\(episodeOne)-1080p"))
        XCTAssertTrue(app.staticTexts[A11yID.TV.Player.elapsed].waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFocus(option(app, "\(episodeTwo)-original"), timeout: 30), "The question over the player")
        press(.menu)
        XCTAssertTrue(poll(timeout: 5) { !self.picker(app).exists && !app.staticTexts[A11yID.TV.Player.elapsed].exists },
                      "Menu closes the question and the player")
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Detail.play]), "On S2:E1's page")
    }

    /// Choosing on the question over the player plays that version in place.
    func test_autoAdvance_choosing_playsTheChosenVersionInPlace() {
        let episodeOne = UITestFixtureIdentity.episodeID(season: 2, episode: 1)
        let episodeTwo = UITestFixtureIdentity.episodeID(season: 2, episode: 2)
        let app = launchAtHomeWithVersions(extraArguments: ["-UITestEarlyCreditsItem", episodeOne])
        app.open(link("play/\(episodeOne)?source=\(episodeOne)-1080p"))
        XCTAssertTrue(app.staticTexts[A11yID.TV.Player.elapsed].waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFocus(option(app, "\(episodeTwo)-original"), timeout: 30), "The question over the player")
        choose("\(episodeTwo)-extended", app)
        XCTAssertTrue(poll(timeout: 10) { !self.picker(app).exists && (self.elapsedSeconds(app) ?? 999) < 30 },
                      "S2:E2 plays from its start in the same player")
        assertPlaying("Extended Edition", app)
    }

    // MARK: - Links (D3)

    /// The Top Shelf's Play follows the page's rule: an unwatched title asks,
    /// over its page.
    func test_topShelfLink_freshStart_asks() {
        let app = launchAtHomeWithVersions()
        app.open(link("play/\(quietAscent)?from=topshelf"))
        XCTAssertTrue(waitForFocus(option(app, "\(quietAscent)-4k"), timeout: 15), "The question")
        choose("\(quietAscent)-1080p", app)
        assertPlaying("1080p", app)
    }

    /// Any other play link never asks: the server's default here.
    func test_plainPlayLink_doesNotAsk() {
        let app = launchAtHomeWithVersions()
        app.open(link("play/\(quietAscent)"))
        assertPlaysWithoutAsking(app)
        assertPlaying("4K HDR10", app)
    }
}
