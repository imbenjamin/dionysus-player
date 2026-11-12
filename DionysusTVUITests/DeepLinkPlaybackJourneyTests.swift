import XCTest

/// `dionysus://play` links' playback parameters on the Apple TV (#406):
/// where to start, Playback Stats and playlists. Tracks, versions and what a
/// link couldn't read are the shared `PlayerViewModel`'s, pinned by its unit
/// tests and iOS's `DeepLinkJourneyTests`.
final class DeepLinkPlaybackJourneyTests: TVUITestCase {
    private func link(_ path: String) -> URL { URL(string: "dionysus://" + path)! }

    /// Signed in on Home, the transport kept up so the elapsed time stays
    /// readable.
    private func launchAtHome(scenario: String = "standard", extraArguments: [String] = []) -> XCUIApplication {
        let app = launch(scenario: scenario, seedSession: true, extraArguments: ["-UITestDisableControlAutoHide", "YES"] + extraArguments)
        XCTAssertTrue(app.buttons[A11yID.TV.Main.heroPlay].waitForExistence(timeout: 10))
        return app
    }

    private func awaitElapsed(_ range: ClosedRange<Double>, _ app: XCUIApplication, _ what: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.staticTexts[A11yID.TV.Player.elapsed].waitForExistence(timeout: 10), "The player", file: file, line: line)
        XCTAssertTrue(poll(timeout: 10) { self.elapsedSeconds(app).map(range.contains) ?? false },
                      "\(what): elapsed read \(app.staticTexts[A11yID.TV.Player.elapsed].label)", file: file, line: line)
    }

    func test_playLink_startsAtTheLinkedTime() {
        let app = launchAtHome()
        app.open(link("play/\(UITestFixtureIdentity.primaryMovieID)?t=1:30"))
        awaitElapsed(90...110, app, "Starts at 1:30")
    }

    /// The fixture movie's second chapter starts at 23:00.
    func test_playLink_startsAtTheLinkedChapter() {
        let app = launchAtHome()
        app.open(link("play/\(UITestFixtureIdentity.primaryMovieID)?chapter=2"))
        awaitElapsed(1380...1400, app, "Starts at chapter 2")
    }

    /// Shown even where the setting hides the Stats icon.
    func test_playLink_opensPlaybackStats() {
        let app = launchAtHome(extraArguments: ["-showPlaybackStatsButtonEnabled", "NO"])
        app.open(link("play/\(UITestFixtureIdentity.primaryMovieID)?stats=1"))
        XCTAssertTrue(app.descendants(matching: .any)[A11yID.TV.Player.statsPanel].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)[A11yID.TV.Player.icon("stats")].exists, "The icon, to close them")
    }

    /// A member plays with the rest of the playlist queued: Next Up offers
    /// the next member, which a movie played alone has none of.
    /// (`earlyCredits` starts a member's credits at 0:05.)
    func test_playLink_forAPlaylistMember_queuesTheRest() {
        let app = launchAtHome(scenario: "earlyCredits")
        app.open(link("play/\(UITestFixtureIdentity.primaryMovieID)?playlist=\(UITestFixtureIdentity.playlistID)"))
        XCTAssertTrue(app.descendants(matching: .any)[A11yID.TV.Player.nextUpCard].waitForExistence(timeout: 15))
    }

    /// A playlist plays what its page's Play would, over that page.
    func test_playLink_forAPlaylist_playsItsPlayTarget_overItsPage() {
        let app = launchAtHome()
        app.open(link("play/\(UITestFixtureIdentity.playlistID)"))
        XCTAssertTrue(app.staticTexts[A11yID.TV.Player.elapsed].waitForExistence(timeout: 10))
        leavePlayer(app)
        let title = app.descendants(matching: .any)[A11yID.TV.Detail.title]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertTrue(title.label.contains("Weekend Watchlist"), "The playlist's page, got \(title.label)")
    }
}
