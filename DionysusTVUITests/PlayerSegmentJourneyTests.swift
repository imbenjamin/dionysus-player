import XCTest

final class PlayerSegmentJourneyTests: TVUITestCase {
    func test_skipIntro_selectSkipsToTheIntrosEnd() {
        let app = openPlayer(scenario: "skipIntro", extraArguments: ["-UITestDisableControlAutoHide", "YES"])
        let skip = app.descendants(matching: .any)[A11yID.TV.Player.skipButton]
        XCTAssertTrue(skip.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForPlayerFocus(app, "skip"))
        press(.select)
        XCTAssertTrue(poll(timeout: 5) { (self.elapsedSeconds(app) ?? 0) >= 5000 }, "Skips to 83:20")
        XCTAssertTrue(poll(timeout: 3) { !skip.exists })
    }

    func test_skipIntro_menuHidesIt_theTransportBringsItBack_andASecondMenuCloses() {
        let app = openPlayer(scenario: "skipIntro", extraArguments: [])
        let skip = app.descendants(matching: .any)[A11yID.TV.Player.skipButton]
        XCTAssertTrue(skip.waitForExistence(timeout: 10))
        // Let the transport fade (4s after playback starts).
        XCTAssertTrue(poll(timeout: 8) { !app.staticTexts[A11yID.TV.Player.elapsed].exists })
        press(.menu)
        XCTAssertTrue(poll(timeout: 3) { !skip.exists }, "Menu hides the button")
        press(.up)
        XCTAssertTrue(skip.waitForExistence(timeout: 3), "It is back while the transport is up")
        XCTAssertTrue(poll(timeout: 8) { !app.staticTexts[A11yID.TV.Player.elapsed].exists })
        press(.menu)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Detail.play]), "A second Menu closes the player")
    }

    /// The part-watched S1:E1 resumes at 12:00, inside credits that start at
    /// 0:05, so the card shows at once and counts down 10s.
    func test_nextUp_playNowPlaysTheNextEpisodeInThePlayer() {
        let app = openEpisodeOne(scenario: "earlyCredits")
        let card = app.descendants(matching: .any)[A11yID.TV.Player.nextUpCard]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForPlayerFocus(app, "nextUp.playNow", timeout: 8), "Focus is the card's once the transport fades")
        press(.select)
        press(.up)
        let title = app.descendants(matching: .any)[A11yID.TV.Player.titleBlock]
        XCTAssertTrue(poll(timeout: 10) { title.exists && title.label.contains("2") && (self.elapsedSeconds(app) ?? 999) < 20 },
                      "The second episode plays from its start in the same player")
    }

    func test_nextUp_closeHidesTheCard_forTheRestOfTheEpisode() {
        let app = openEpisodeOne(scenario: "earlyCredits")
        let card = app.descendants(matching: .any)[A11yID.TV.Player.nextUpCard]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForPlayerFocus(app, "nextUp.playNow", timeout: 8))
        press(.right)
        XCTAssertTrue(waitForPlayerFocus(app, "nextUp.close"))
        press(.select)
        XCTAssertTrue(poll(timeout: 3) { !card.exists })
        Thread.sleep(forTimeInterval: 12)
        XCTAssertFalse(card.exists, "Past where the countdown would have ended, nothing advanced")
    }

    func test_nextUp_countdownReachingZero_advancesByItself() {
        let app = openEpisodeOne(scenario: "earlyCredits")
        XCTAssertTrue(app.descendants(matching: .any)[A11yID.TV.Player.nextUpCard].waitForExistence(timeout: 10))
        // The transport fades before the countdown ends, and comes back up as
        // the next item loads, so read the time only while it shows.
        let elapsed = app.staticTexts[A11yID.TV.Player.elapsed]
        XCTAssertTrue(poll(timeout: 16) { elapsed.exists && (self.elapsedSeconds(app) ?? 999) < 20 },
                      "The next episode starts when the countdown ends")
    }

    /// Home's Continue Watching rail: the movie, then S1:E1.
    private func openEpisodeOne(scenario: String) -> XCUIApplication {
        let app = launch(scenario: scenario, seedSession: true)
        waitForHomeThenFirstTile(app)
        press(.right)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Main.tile(UITestFixtureIdentity.episodeID(season: 1, episode: 1))]))
        openDetailFromFocusedTile(app)
        press(.select)
        XCTAssertTrue(app.descendants(matching: .any)[A11yID.TV.Player.focus].waitForExistence(timeout: 10))
        return app
    }
}
