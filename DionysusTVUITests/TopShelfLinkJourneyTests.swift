import XCTest

/// Top Shelf links (M6), opened as tvOS opens them, and the same links
/// typed by hand without a server (#406).
final class TopShelfLinkJourneyTests: TVUITestCase {
    private func link(_ action: String, _ itemID: String, server: String? = UITestFixtureIdentity.serverAddress) -> URL {
        var components = URLComponents()
        components.scheme = "dionysus"
        components.host = action
        components.path = "/" + itemID
        components.queryItems = server.map { [URLQueryItem(name: "server", value: $0)] }
        return components.url!
    }

    func test_itemLink_opensTheDetailPage_overHome() {
        let app = launchAtHome()
        app.open(link("item", UITestFixtureIdentity.primaryMovieID))
        let play = app.buttons[A11yID.TV.Detail.play]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFocus(play))
        press(.menu)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Main.heroPlay]), "Menu goes back to Home")
    }

    func test_playLink_playsOverTheDetailPage() {
        let app = launchAtHome()
        app.open(link("play", UITestFixtureIdentity.primaryMovieID))
        XCTAssertTrue(app.staticTexts[A11yID.TV.Player.elapsed].waitForExistence(timeout: 10))
        leavePlayer(app)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Detail.play]), "Leaving the player lands on the title's page")
    }

    func test_playLink_whilePlaying_switchesTitle() {
        let app = openEpisodeOne(scenario: "standard")
        app.open(link("play", UITestFixtureIdentity.primaryMovieID))
        XCTAssertTrue(app.staticTexts[A11yID.TV.Player.elapsed].waitForExistence(timeout: 10))
        leavePlayer(app)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Detail.play]))
        let title = app.descendants(matching: .any)[A11yID.TV.Detail.title]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertFalse(title.label.contains(UITestFixtureIdentity.seriesName), "The page is the movie's, not the episode's show")
    }

    /// `server=` is optional (#406): a link typed for debugging applies to
    /// whichever server is signed in.
    func test_itemLink_withNoServer_opensTheDetailPage() {
        let app = launchAtHome()
        app.open(link("item", UITestFixtureIdentity.primaryMovieID, server: nil))
        XCTAssertTrue(app.buttons[A11yID.TV.Detail.play].waitForExistence(timeout: 10))
    }

    /// Signed out, a link waits through sign-in and then opens (#406;
    /// before, it was dropped).
    func test_itemLink_whileSignedOut_opensAfterSignIn() {
        let app = launch()
        app.open(link("item", UITestFixtureIdentity.primaryMovieID, server: nil))
        connectToDiscoveredServer(app)
        let user = app.buttons[A11yID.TV.Onboarding.user(UITestFixtureIdentity.passwordlessUserID)]
        XCTAssertTrue(user.waitForExistence(timeout: 5))
        press(.right)
        XCTAssertTrue(waitForFocus(user))
        press(.select)
        XCTAssertTrue(app.buttons[A11yID.TV.Detail.play].waitForExistence(timeout: 10), "The linked title, once signed in")
    }

    func test_linkForAnotherServer_isIgnored() {
        let app = launchAtHome()
        app.open(link("item", UITestFixtureIdentity.primaryMovieID, server: "http://elsewhere.invalid"))
        XCTAssertFalse(app.buttons[A11yID.TV.Detail.play].waitForExistence(timeout: 3))
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Main.heroPlay]))
    }

    func test_itemLink_forAMissingTitle_opensAPageWithRetry() {
        let app = launchAtHome()
        app.open(link("item", "no-such-item"))
        XCTAssertTrue(app.buttons[A11yID.TV.Detail.retry].waitForExistence(timeout: 10))
    }
}
