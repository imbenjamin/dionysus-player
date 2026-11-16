import XCTest

/// Choosing a version to play (#289). What decides is whether the title has
/// a resume point, not the button (Benjamin, 2026-11-13): without one, Play
/// asks which version when there are several, marking the remembered one;
/// with one, Resume and Restart both play the remembered version, and ask
/// only when nothing is remembered. Auto-advance asks only when it can't
/// carry the choice over. The stub's `multipleVersions` scenario gives movie 1 a
/// 4K HDR10 and a 1080p version, movie 2 an Original and a Director's Cut,
/// Season 1 4K and 1080p throughout, and S2:E2 two editions.
///
/// What played is read from Playback Stats' Version row
/// (`A11yID.PlaybackStats.versionValue`), which names the version the player
/// asked the server for.
final class MediaVersionJourneyTests: UITestCase {
    private let quietAscent = UITestFixtureIdentity.primaryMovieID // movie-01, unwatched
    private let signalFire = UITestFixtureIdentity.partWatchedMovieID // movie-02, part-watched

    private func link(_ string: String) -> URL { URL(string: "dionysus://" + string)! }

    /// Opens `url` in the running app, accepting the system's "Open in
    /// Dionysus?" prompt if it asks (as `DeepLinkJourneyTests` does).
    private func openLink(_ url: URL) {
        XCUIDevice.shared.system.open(url)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let open = springboard.buttons["Open"]
        if open.waitForExistence(timeout: 2) { open.tap() }
    }

    /// Launches under `scenario` and opens `itemID`'s page from Home.
    @discardableResult
    private func openFromHome(_ itemID: String, scenario: String = "multipleVersions") -> AssetDetailScreen {
        launch(scenario: scenario)
        let home = HomeScreen(app: app)
        home.awaitLoaded()
        home.openItem(itemID)
        let detail = AssetDetailScreen(app: app)
        detail.awaitLoaded()
        return detail
    }

    /// Launches and opens `itemID`'s page by its link, for a page Home
    /// doesn't list.
    @discardableResult
    private func openByLink(_ path: String) -> AssetDetailScreen {
        launch(scenario: "multipleVersions")
        HomeScreen(app: app).awaitLoaded()
        openLink(link(path))
        let detail = AssetDetailScreen(app: app)
        detail.awaitLoaded()
        return detail
    }

    /// Opens Playback Stats and checks the Version row names `label`.
    private func assertPlaying(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let player = PlayerScreen(app: app)
        player.awaitControls(file: file, line: line)
        player.statsButton.tap()
        player.statsVersionValue.awaitExistence("Playback Stats' Version row", file: file, line: line)
        XCTAssertEqual(player.statsVersionValue.label, label, file: file, line: line)
    }

    /// Proves the question does *not* come: the player comes up with no
    /// version button ever shown on the way.
    private func assertPlaysWithoutAsking(_ detail: AssetDetailScreen, file: StaticString = #filePath, line: UInt = #line) {
        let player = PlayerScreen(app: app)
        let deadline = Date().addingTimeInterval(UITestCase.defaultTimeout)
        while !player.closeButton.exists, Date() < deadline {
            XCTAssertFalse(detail.anyVersionOption.exists, "No version question on the way to the player", file: file, line: line)
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        player.awaitControls(file: file, line: line)
    }

    private func closePlayer() {
        let player = PlayerScreen(app: app)
        player.close()
        player.closeButton.awaitDisappearance("the player")
        AssetDetailScreen(app: app).awaitLoaded()
    }

    // MARK: - Starting a title

    func test_play_unwatchedMultiVersionMovie_asks_andPlaysTheChosenVersion() {
        let detail = openFromHome(quietAscent)
        detail.playButton.tap()
        detail.versionOption("\(quietAscent)-4k").awaitExistence("the 4K HDR10 version")
        detail.versionOption("\(quietAscent)-1080p").tap()
        assertPlaying("1080p")
    }

    /// A part-watched title with nothing remembered asks on Resume (D4);
    /// once answered, Restart plays that version without asking, from 0.
    func test_restart_withResumePointAndRememberedVersion_doesNotAsk() {
        let detail = openFromHome(signalFire)
        detail.playButton.tap()
        detail.versionOption("\(signalFire)-directors-cut").awaitExistence("the version question on Resume, nothing remembered")
        detail.versionOption("\(signalFire)-directors-cut").tap()
        assertPlaying("Director's Cut")
        closePlayer()

        detail.restartButton.awaitExistence("Restart, for a part-watched title")
        detail.restartButton.tap()
        assertPlaysWithoutAsking(detail)
        assertPlaying("Director's Cut")
    }

    /// The remembered version is marked when an unwatched title asks again
    /// (D8). The pick is made, then the app relaunched without resetting
    /// state: the stub forgets the session's progress, so the title is
    /// unwatched again, while the remembered pick (on the device) stays. The
    /// mark's wording is localized, so this checks only that the remembered
    /// version's button reads differently from its plain label while the
    /// other's doesn't.
    func test_play_lastPlayedIsMarked() {
        let detail = openFromHome(quietAscent)
        detail.playButton.tap()
        detail.versionOption("\(quietAscent)-1080p").awaitExistence("the version question")
        detail.versionOption("\(quietAscent)-1080p").tap()
        PlayerScreen(app: app).awaitControls()

        launch(scenario: "multipleVersions", resetsState: false)
        let home = HomeScreen(app: app)
        home.awaitLoaded()
        home.openItem(quietAscent)
        let again = AssetDetailScreen(app: app)
        again.play()
        let remembered = again.versionOption("\(quietAscent)-1080p")
        remembered.awaitExistence("the remembered version, asked again on Play")
        XCTAssertNotEqual(remembered.label, "1080p", "The remembered version carries a mark")
        XCTAssertEqual(again.versionOption("\(quietAscent)-4k").label, "4K HDR10", "The other version doesn't")
    }

    /// Dismissing the question plays nothing (review focus 2), and Play asks
    /// again every time after: the row's old dialog, presented from a
    /// computed binding, silently skipped the question on the third or
    /// fourth Play of a session, so this goes round four times.
    func test_play_cancel_playsNothing() {
        let detail = openFromHome(quietAscent)
        let option = detail.versionOption("\(quietAscent)-1080p")
        for attempt in 1...4 {
            detail.playButton.tap()
            option.awaitExistence("the version question, Play number \(attempt)")
            detail.dismissVersionQuestion()
            option.awaitDisappearance("the version question, Play number \(attempt)")
            // Long enough for a player to have come up had the dismissal played.
            RunLoop.current.run(until: Date().addingTimeInterval(2))
            XCTAssertFalse(PlayerScreen(app: app).closeButton.exists, "Nothing plays (Play number \(attempt))")
            detail.playButton.awaitExistence("the detail page, still showing")
        }
    }

    /// A row's Play asks too (D1): the row's item is listed without its
    /// sources, so they're fetched first.
    func test_episodeRowPlay_asks() {
        let detail = openByLink("item/\(UITestFixtureIdentity.seriesID)?season=1")
        let episodeTwo = UITestFixtureIdentity.episodeID(season: 1, episode: 2)
        let rowPlay = detail.episodePlayButton(episodeTwo)
        rowPlay.awaitExistence("episode 2's row")
        rowPlay.tap()
        detail.versionOption("\(episodeTwo)-1080p").awaitExistence("the version question for episode 2")
        detail.versionOption("\(episodeTwo)-1080p").tap()
        assertPlaying("1080p")
    }

    /// A playlist row's Play asks too (D1): the playlist's first member is
    /// movie-01, unwatched, in 4K HDR10 and 1080p.
    func test_playlistRowPlay_multiVersionMember_asks() {
        let detail = openByLink("item/\(UITestFixtureIdentity.playlistID)")
        let row = detail.playlistPlayButton("playlist-entry-1")
        row.awaitExistence("the playlist's first row's Play")
        row.tap()
        detail.versionOption("\(quietAscent)-4k").awaitExistence("the version question for the playlist's first member")
        detail.versionOption("\(quietAscent)-1080p").tap()
        assertPlaying("1080p")
    }

    /// Resume with nothing remembered asks, and remembers the answer (D4).
    func test_resume_noRememberedVersion_asks_andRemembers() {
        let episodeOne = UITestFixtureIdentity.episodeID(season: 1, episode: 1)
        let detail = openFromHome(episodeOne)
        detail.playButton.tap()
        detail.versionOption("\(episodeOne)-4k").awaitExistence("the version question on Resume")
        detail.versionOption("\(episodeOne)-4k").tap()
        assertPlaying("4K HDR10")
        closePlayer()

        detail.playButton.tap()
        assertPlaysWithoutAsking(detail)
        assertPlaying("4K HDR10")
    }

    /// A single-version title plays straight away, as before.
    func test_singleVersionMovie_playsWithoutAsking() {
        let detail = openFromHome(quietAscent, scenario: "standard")
        detail.playButton.tap()
        assertPlaysWithoutAsking(detail)
    }

    // MARK: - Auto-advance (D2)

    /// S1:E1 played in 1080p; S1:E2 has a 1080p too, so the advance carries
    /// it over without asking. Reaching the end with a next episode advances
    /// at once (the countdown's remaining time is already 0).
    func test_autoAdvance_sameLabel_doesNotAsk() {
        let episodeOne = UITestFixtureIdentity.episodeID(season: 1, episode: 1)
        let detail = openFromHome(episodeOne)
        detail.playButton.tap()
        detail.versionOption("\(episodeOne)-1080p").awaitExistence("the version question on Resume")
        detail.versionOption("\(episodeOne)-1080p").tap()
        let player = PlayerScreen(app: app)
        player.awaitControls()
        player.scrubToEnd()

        // The player closes and reopens on S1:E2 faster than a wait for the
        // close button to go can see, so the new session is told by its
        // position: back near the start, where S1:E1 was at its end. No
        // question may show on the way.
        let deadline = Date().addingTimeInterval(UITestCase.defaultTimeout)
        var advanced = false
        while Date() < deadline {
            XCTAssertFalse(detail.anyVersionOption.exists, "No version question on the advance")
            if player.closeButton.exists, let seconds = position(player), seconds < 20 { advanced = true; break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertTrue(advanced, "S1:E2 plays from its start")
        assertPlaying("1080p")
    }

    /// The scrubber's position in seconds ("12:03" or "1:12:03"), or `nil`
    /// before it reads as a time (as `PlayerJourneyTests` reads it).
    private func position(_ player: PlayerScreen) -> Double? {
        let parts = ((player.scrubber.value as? String) ?? "").split(separator: ":").compactMap { Double($0) }
        return parts.count >= 2 ? parts.reduce(0) { $0 * 60 + $1 } : nil
    }

    /// S2:E1 played in 1080p; S2:E2's versions are editions, none labelled
    /// 1080p, so the advance asks.
    func test_autoAdvance_noMatchingVersion_asks() {
        let episodeOne = UITestFixtureIdentity.episodeID(season: 2, episode: 1)
        let episodeTwo = UITestFixtureIdentity.episodeID(season: 2, episode: 2)
        let detail = openByLink("item/\(episodeOne)")
        detail.playButton.tap()
        detail.versionOption("\(episodeOne)-1080p").awaitExistence("the version question for S2:E1")
        detail.versionOption("\(episodeOne)-1080p").tap()
        let player = PlayerScreen(app: app)
        player.awaitControls()
        player.scrubToEnd()

        detail.versionOption("\(episodeTwo)-extended").awaitExistence("the version question for S2:E2, after the advance")
        detail.versionOption("\(episodeTwo)-extended").tap()
        assertPlaying("Extended Edition")
    }
}
