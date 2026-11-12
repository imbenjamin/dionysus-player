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

    /// The grid goes on Home's stack with the link's facets chosen: Genre
    /// Action and Favorites leave `Iron Meridian` alone, as picking both does.
    func testLibraryLink_opensTheGrid_filtered() {
        launchAtHome()
        openLink(link("library/\(UITestFixtureIdentity.moviesLibraryID)?genre=Action&filter=favorites&sort=dateAdded&order=desc"))
        let collection = CollectionScreen(app: app)
        collection.card(UITestFixtureIdentity.movieID(4)).awaitExistence("the one Action favourite")
        XCTAssertFalse(collection.card(UITestFixtureIdentity.partWatchedMovieID).exists, "Sci-Fi, not a favourite")
        collection.resetFiltersButton.awaitExistence("Reset, for the link's filters")
        collection.resetFiltersButton.tap()
        collection.card(UITestFixtureIdentity.partWatchedMovieID).awaitExistence("the whole library once reset")
        app.navigationBars.buttons.firstMatch.tap()
        HomeScreen(app: app).awaitLoaded()
    }

    func testProfileLink_pushesAboutsLicense() {
        launchAtHome()
        openLink(link("profile/about/license"))
        app.staticTexts[A11yID.About.appLicense].awaitExistence("the app's licence")
    }

    func testProfileLink_pushesAdvancedPlayback() {
        launchAtHome()
        openLink(link("profile/playback/advanced"))
        app.steppers[A11yID.Profile.readAheadBufferStepper].awaitExistence("Advanced playback's read-ahead stepper")
    }

    /// Filled, not submitted: approving signs a device in, so it stays a tap.
    func testQuickConnectLink_fillsTheCode_withoutApproving() {
        launchAtHome()
        let code = UITestFixtureIdentity.quickConnectApprovableCode
        openLink(link("quickconnect/approve?code=\(code)"))
        let screen = QuickConnectApprovalScreen(app: app)
        screen.codeField.awaitExistence("the Quick Connect code field")
        XCTAssertEqual(screen.codeField.value as? String, code)
        XCTAssertFalse(screen.successMessage.exists, "A link never approves the code")
        screen.authorizeButton.tap()
        screen.successMessage.awaitExistence("approval once Authorize is tapped")
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

    /// The show opens on the linked season: its episodes are listed.
    func testItemLink_opensAShowOnTheLinkedSeason() {
        launchAtHome()
        openLink(link("item/\(UITestFixtureIdentity.seriesID)?season=2"))
        let page = AssetDetailScreen(app: app)
        page.episodeRow(UITestFixtureIdentity.episodeID(season: 2, episode: 1)).awaitExistence("season 2's first episode")
        XCTAssertFalse(page.episodeRow(UITestFixtureIdentity.episodeID(season: 1, episode: 1)).exists, "Season 1 isn't listed")
    }

    /// Cast & Crew is a tab: the link opens it, so the cast shows.
    func testItemLink_opensTheCastTab() {
        launchAtHome()
        openLink(link("item/\(UITestFixtureIdentity.primaryMovieID)?section=cast"))
        AssetDetailScreen(app: app).castMembers.firstMatch.awaitExistence("the cast, on the linked tab")
    }

    func testItemLink_forASeasonTheShowDoesntHave_saysSo() {
        let home = launchAtHomeHearingAnnouncements()
        openLink(link("item/\(UITestFixtureIdentity.seriesID)?season=9"))
        awaitAnnouncement("This show has no season 9.", on: home)
    }

    func testItemLink_forASectionACollectionDoesntHave_saysSo() {
        let home = launchAtHomeHearingAnnouncements()
        openLink(link("item/\(UITestFixtureIdentity.boxSetID)?section=chapters"))
        awaitAnnouncement("This title has no chapters to show.", on: home)
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

    // MARK: - Playback parameters

    /// The player's position off the scrubber's value, the unlocalized "m:ss"
    /// (or "h:mm:ss") the playhead reads.
    private func position(_ player: PlayerScreen) -> Double? {
        let parts = ((player.scrubber.value as? String) ?? "").split(separator: ":").compactMap { Double($0) }
        return parts.count >= 2 ? parts.reduce(0) { $0 * 60 + $1 } : nil
    }

    /// Waits for the playhead to settle in `range`; the fake engine plays on
    /// at 1x, so each range leaves room for a few seconds of playback.
    private func awaitPosition(_ range: ClosedRange<Double>, of player: PlayerScreen, _ what: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        let reached = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in self.position(player).map(range.contains) ?? false }, object: nil
        )
        XCTAssertEqual(XCTWaiter().wait(for: [reached], timeout: Self.defaultTimeout), .completed,
                       "\(what): the playhead read \(player.scrubber.value ?? "nothing")", file: file, line: line)
    }

    private func openPlayer(_ path: String) -> PlayerScreen {
        openLink(link(path))
        let player = PlayerScreen(app: app)
        player.closeButton.awaitExistence("the player")
        return player
    }

    func testPlayLink_startsAtTheLinkedTime() {
        launchAtHome()
        let player = openPlayer("play/\(UITestFixtureIdentity.primaryMovieID)?t=1:30")
        awaitPosition(90...110, of: player, "Starts at 1:30")
    }

    /// Chapters are 1-based, as shown: the fixture movie's second starts at
    /// 23:00, a quarter of its 92 minutes.
    func testPlayLink_startsAtTheLinkedChapter() {
        launchAtHome()
        let player = openPlayer("play/\(UITestFixtureIdentity.primaryMovieID)?chapter=2")
        awaitPosition(1380...1400, of: player, "Starts at chapter 2")
    }

    /// Jellyfin's stream indexes: the fixture's audio stream 1 and subtitle
    /// stream 3, which the fake engine lists as its Commentary track and its
    /// placed-cue Signs track.
    func testPlayLink_playsTheLinkedTracks() {
        launchAtHome()
        let player = openPlayer("play/\(UITestFixtureIdentity.primaryMovieID)?audio=1&subtitle=3")
        app.descendants(matching: .any).matching(identifier: A11yID.Player.plainSubtitle)
            .matching(NSPredicate(format: "label == %@", UITestFixtureIdentity.alignedSubtitleCueText)).firstMatch
            .awaitExistence("the linked subtitle track's cue")
        player.tracksButton.tap()
        player.trackNavigationRow("audio").tap()
        let commentary = player.trackOption("audio", 1)
        commentary.awaitExistence("the linked audio track's row")
        XCTAssertTrue(commentary.isSelected, "The linked audio track plays")
    }

    /// Opened even where the setting hides the button, which then shows so
    /// the overlay can be closed.
    func testPlayLink_opensPlaybackStats() {
        launch(extraArguments: ["-showPlaybackStatsButtonEnabled", "NO"])
        HomeScreen(app: app).awaitLoaded()
        let player = openPlayer("play/\(UITestFixtureIdentity.primaryMovieID)?stats=1")
        player.statsPageIndicator.awaitExistence("Playback Stats")
        player.statsButton.awaitExistence("the stats button, to close them")
    }

    /// A member plays from the playlist's page, with the rest queued after
    /// it: Next Up offers the playlist's next member, which a movie played
    /// alone has none of. (`earlyCredits` starts a member's credits at 0:05.)
    func testPlayLink_forAPlaylistMember_queuesTheRest() {
        launch(scenario: "earlyCredits")
        HomeScreen(app: app).awaitLoaded()
        let player = openPlayer("play/\(UITestFixtureIdentity.primaryMovieID)?playlist=\(UITestFixtureIdentity.playlistID)")
        player.nextUpCard.awaitExistence("Next Up, for the playlist's next member")
    }

    /// `offline=1` plays the downloaded copy, from the download's own page.
    func testPlayLink_offline_playsTheDownload() {
        launchAtHome()
        HomeScreen(app: app).openItem(UITestFixtureIdentity.primaryMovieID)
        let detail = AssetDetailScreen(app: app)
        detail.awaitLoaded()
        detail.downloadButton.tap()
        let audioChoice = app.buttons["ENG EAC3"]
        audioChoice.awaitExistence("the audio-track prompt's default track option")
        audioChoice.tap()
        detail.awaitDownloadCompletion()

        let player = openPlayer("play/\(UITestFixtureIdentity.primaryMovieID)?offline=1")
        player.close()
        app.buttons[A11yID.Downloads.playButton].awaitExistence("the download's page under the player")
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

    func testLibraryLink_forAnUnknownLibrary_saysSo_andStaysPut() {
        let home = launchAtHomeHearingAnnouncements()
        openLink(link("library/\(UITestFixtureIdentity.missingItemID)"))
        awaitAnnouncement("This library can't be found.", on: home)
        home.awaitLoaded()
    }

    func testProfileLink_toAPageProfileDoesntHave_opensProfile_andSaysSo() {
        let home = launchAtHomeHearingAnnouncements()
        openLink(link("profile/nope"))
        awaitAnnouncement("Profile has no such page.", on: home)
        ProfileScreen(app: app).awaitLoaded()
    }

    func testQuickConnectLink_withQuickConnectOff_saysSo() {
        launch(scenario: "quickConnectDisabled", extraArguments: ["-UITestSimulateVoiceOver", "YES"])
        let home = HomeScreen(app: app)
        home.awaitLoaded()
        openLink(link("quickconnect/approve?code=123456"))
        awaitAnnouncement("Quick Connect is off on this server.", on: home)
        XCTAssertFalse(QuickConnectApprovalScreen(app: app).codeField.exists)
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

    /// A start time it can't read is said; the title plays as Play would.
    func testPlayLink_withAnUnreadableTime_playsAndSaysSo() {
        let home = launchAtHomeHearingAnnouncements()
        openLink(link("play/\(UITestFixtureIdentity.primaryMovieID)?t=soon"))
        let player = PlayerScreen(app: app)
        player.awaitControls()
        // The probe sits under the player's cover; it keeps what was said.
        player.close()
        awaitAnnouncement("Couldn't read the start time.", on: home)
    }

    /// Asked for the downloaded copy of a title that has none, it streams.
    func testPlayLink_offline_withNoDownload_streamsAndSaysSo() {
        let home = launchAtHomeHearingAnnouncements()
        openLink(link("play/\(UITestFixtureIdentity.primaryMovieID)?offline=1"))
        let player = PlayerScreen(app: app)
        player.awaitControls()
        // The probe sits under the player's cover; it keeps what was said.
        player.close()
        awaitAnnouncement("This title isn't downloaded, so it's streaming.", on: home)
    }

    /// A chapter the title doesn't have is said, after the title loads.
    func testPlayLink_toAMissingChapter_saysSo() {
        let home = launchAtHomeHearingAnnouncements()
        openLink(link("play/\(UITestFixtureIdentity.primaryMovieID)?chapter=9"))
        let player = PlayerScreen(app: app)
        player.awaitControls()
        // The probe sits under the player's cover; it keeps what was said.
        player.close()
        awaitAnnouncement("This title has no chapter 9.", on: home)
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
