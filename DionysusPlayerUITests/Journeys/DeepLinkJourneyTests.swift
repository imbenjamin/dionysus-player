import XCTest

/// `dionysus://` links (#406), opened as the system opens them.
///
/// Through `XCUIDevice.shared.system.open`, into the app already running.
/// `XCUIApplication.open` relaunches it instead (seen in the app's log), so
/// every link arrived during a cold launch's session restore and the warm
/// path (the player closing first, an unreadable link refused at once) went
/// untested.
final class DeepLinkJourneyTests: UITestCase {
    private func link(_ string: String) -> URL { URL(string: "dionysus://" + string)! }

    /// Opens `url` in the running app, accepting the system's "Open in
    /// Dionysus?" prompt if it asks.
    private func openLink(_ url: URL) {
        XCUIDevice.shared.system.open(url)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let open = springboard.buttons["Open"]
        if open.waitForExistence(timeout: 2) { open.tap() }
    }

    private func launchAtHome() {
        launch()
        HomeScreen(app: app).awaitLoaded()
    }

    // MARK: - Places

    func testTabLinks_selectTheirTab() {
        launchAtHome()
        openLink(link("downloads"))
        DownloadsScreen(app: app).emptyState.awaitExistence("the Downloads tab")
        openLink(link("profile"))
        ProfileScreen(app: app).awaitLoaded()
        openLink(link("home"))
        HomeScreen(app: app).awaitLoaded()
    }

    func testSearchLink_runsTheQuery() {
        launchAtHome()
        openLink(link("search?q=Quiet"))
        SearchScreen(app: app).result(UITestFixtureIdentity.primaryMovieID)
            .awaitExistence("a result for the linked query")
    }

    // MARK: - Titles

    /// The page goes on Home's stack, so Back returns to Home.
    func testItemLink_opensThePage_overHome() {
        launchAtHome()
        openLink(link("item/\(UITestFixtureIdentity.primaryMovieID)"))
        AssetDetailScreen(app: app).playButton.awaitExistence("the linked title's Play button")
        app.navigationBars.buttons.firstMatch.tap()
        HomeScreen(app: app).awaitLoaded()
    }

    func testItemLink_forAMissingTitle_saysItCantBeFound() {
        launchAtHome()
        openLink(link("item/\(UITestFixtureIdentity.missingItemID)"))
        app.descendants(matching: .any)[A11yID.AssetDetail.notFoundMessage]
            .awaitExistence("This Title Can't Be Found")
    }

    /// The player opens over the title's page, so closing it lands there.
    func testPlayLink_playsOverThePage() {
        launchAtHome()
        openLink(link("play/\(UITestFixtureIdentity.primaryMovieID)"))
        let player = PlayerScreen(app: app)
        player.closeButton.awaitExistence("the player")
        player.closeButton.tap()
        AssetDetailScreen(app: app).playButton.awaitExistence("the title's page under the player")
    }

    /// A show plays what its page's Play would.
    func testPlayLink_forAShow_playsAnEpisode() {
        launchAtHome()
        openLink(link("play/\(UITestFixtureIdentity.seriesID)"))
        PlayerScreen(app: app).closeButton.awaitExistence("the player")
    }

    /// Well inside `DeepLinkPresentations.playerCloseLimit` (10 s), after
    /// which the player would be dismissed without reporting its stop: a
    /// player still up this long hasn't closed itself.
    private let playerClosesItselfWithin: TimeInterval = 5

    /// A link arriving mid-playback closes the player the way its own close
    /// button does (`PlayerCloseRequest`, reporting the stop), then opens
    /// what it asked for.
    func testLink_whilePlaying_closesThePlayerFirst() {
        launchAtHome()
        openLink(link("play/\(UITestFixtureIdentity.primaryMovieID)"))
        let player = PlayerScreen(app: app)
        player.closeButton.awaitExistence("the player")
        openLink(link("search?q=Quiet"))
        XCTAssertTrue(player.closeButton.waitForNonExistence(timeout: playerClosesItselfWithin), "The player closes itself")
        SearchScreen(app: app).result(UITestFixtureIdentity.primaryMovieID)
            .awaitExistence("a result for the linked query")
    }

    // MARK: - Fallbacks

    /// A refusal's toast can be gone by the time `open` returns, so these
    /// read what it announced (simulated VoiceOver's probe) instead.
    @discardableResult
    private func launchAtHomeHearingAnnouncements() -> HomeScreen {
        launch(extraArguments: ["-UITestSimulateVoiceOver", "YES"])
        let home = HomeScreen(app: app)
        home.awaitLoaded()
        return home
    }

    private func awaitAnnouncement(_ expected: String, on home: HomeScreen, file: StaticString = #filePath, line: UInt = #line) {
        let said = NSPredicate(format: "label == %@", expected)
        XCTAssertEqual(
            XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: said, object: home.lastAnnouncement)], timeout: 5),
            .completed, "Expected the announcement \"\(expected)\", got \"\(home.lastAnnouncement.label)\"", file: file, line: line
        )
    }

    func testLinkForAnotherServer_isRefused() {
        let home = launchAtHomeHearingAnnouncements()
        openLink(link("item/\(UITestFixtureIdentity.primaryMovieID)?server=http://elsewhere.invalid"))
        awaitAnnouncement("This link is for another server.", on: home)
        XCTAssertFalse(AssetDetailScreen(app: app).playButton.exists)
    }

    func testMalformedLink_saysSo_andStaysPut() {
        let home = launchAtHomeHearingAnnouncements()
        openLink(link("nowhere"))
        awaitAnnouncement("This link can't be opened.", on: home)
        home.awaitLoaded()
    }

    /// A play link to something with nothing to play (here a library) opens
    /// its page and says so.
    func testPlayLink_forSomethingUnplayable_saysSo() {
        let home = launchAtHomeHearingAnnouncements()
        openLink(link("play/\(UITestFixtureIdentity.moviesLibraryID)"))
        awaitAnnouncement("Nothing to play here.", on: home)
        XCTAssertFalse(PlayerScreen(app: app).closeButton.exists)
    }

    // MARK: - Cold launch

    /// `XCUIApplication.open` relaunches the app with the link, as opening one
    /// with the app closed does: it waits for the session to restore.
    func testLink_atColdLaunch_opensOnceRestored() {
        launchAtHome()
        app.open(link("item/\(UITestFixtureIdentity.primaryMovieID)"))
        AssetDetailScreen(app: app).playButton.awaitExistence("the linked title after a cold launch")
    }

    func testUnreadableLink_atColdLaunch_saysSoOnceRestored() {
        launchAtHomeHearingAnnouncements()
        app.open(link("nowhere"))
        awaitAnnouncement("This link can't be opened.", on: HomeScreen(app: app))
    }

    /// A link that arrives signed out waits through sign-in.
    func testLinkWhileSignedOut_opensAfterSignIn() {
        launch(signedIn: false)
        let serverSetup = ServerSetupScreen(app: app)
        let server = serverSetup.scanForStubServer()
        openLink(link("item/\(UITestFixtureIdentity.primaryMovieID)"))
        server.tap()
        let login = LoginScreen(app: app)
        login.awaitLoaded()
        login.userTile(UITestFixtureIdentity.passwordlessUserID).tap()
        AssetDetailScreen(app: app).playButton.awaitExistence("the linked title, once signed in")
    }
}
