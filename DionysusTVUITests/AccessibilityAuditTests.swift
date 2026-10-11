import XCTest

/// `performAccessibilityAudit()` over the Apple TV's signed-in screens: the
/// tvOS counterpart of the iOS suite's file of the same name, gating on the
/// same structural audit types for the same reasons (see its
/// `auditedTypes`). Each test gets a screen on screen and asks.
///
/// Every suppression in `isKnownAcceptable` names the element it's for and
/// why; none is scoped to an audit type alone.
final class AccessibilityAuditTests: TVUITestCase {
    func test_home() throws {
        let app = launchAtHome()
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Main.heroPlay], timeout: 10))
        try audit(app)
    }

    /// The open sidebar (M5), and with many libraries its Libraries row.
    func test_openSidebar() throws {
        let app = launchAtHome()
        openRailFromHome(app)
        XCTAssertTrue(waitForExpanded(app.buttons[A11yID.TV.Sidebar.home]))
        try audit(app)
    }

    func test_openSidebar_withLibrariesFolded() throws {
        let app = launchAtHome(scenario: "manyLibraries")
        openRailFromHome(app)
        XCTAssertTrue(waitForExpanded(app.buttons[A11yID.TV.Sidebar.home]))
        XCTAssertTrue(app.buttons[A11yID.TV.Sidebar.librariesGroup].exists)
        try audit(app)
    }

    func test_moviePage() throws {
        let app = launchAtHomeTile()
        openDetailFromFocusedTile(app)
        try audit(app)
    }

    func test_showPage() throws {
        let app = launchAtHome()
        openRailFromHome(app)
        pressDown(until: app.buttons[A11yID.TV.Sidebar.library(UITestFixtureIdentity.showsLibraryID)])
        press(.select)
        let tile = app.buttons[A11yID.TV.Library.tile(UITestFixtureIdentity.seriesID)]
        XCTAssertTrue(waitForFocus(tile, timeout: 10))
        openDetailFromFocusedTile(app)
        XCTAssertTrue(app.buttons[A11yID.TV.Detail.episode(UITestFixtureIdentity.episodeID(season: 1, episode: 1))].waitForExistence(timeout: 10))
        try audit(app)
    }

    func test_libraryGrid() throws {
        let app = launchAtHome()
        _ = openMovies(app)
        try audit(app)
    }

    /// An open dropdown list, and the sort list with its two groups (M5).
    func test_libraryGridOpenList() throws {
        let app = launchAtHome()
        _ = openMovies(app)
        press(.up)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Library.filter("genre")]))
        press(.select)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Library.option("genre", "all")]))
        try audit(app)
        press(.menu)
        let sort = app.buttons[A11yID.TV.Library.sort]
        for _ in 0..<8 where !sort.hasFocus { press(.right) }
        XCTAssertTrue(waitForFocus(sort))
        press(.select)
        XCTAssertTrue(app.otherElements[A11yID.TV.Library.list("sort")].waitForExistence(timeout: 5))
        try audit(app)
    }

    /// A See All grid, pushed from Home.
    func test_seeAllGrid() throws {
        let app = launchAtHome()
        let seeAll = app.buttons[A11yID.TV.Main.seeAll("Recently Added Movies")]
        focusFirstRailTile(app)
        press(.down, times: 2)
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        for _ in 0..<20 where !(seeAll.exists && seeAll.hasFocus) { press(.right) }
        XCTAssertTrue(waitForFocus(seeAll))
        press(.select)
        XCTAssertTrue(waitForFocus(firstLibraryTile(app)))
        try audit(app)
    }

    /// Full Details, laid over a movie's page.
    func test_fullDetails() throws {
        let app = launchAtHomeTile()
        openDetailFromFocusedTile(app)
        let details = app.buttons[A11yID.TV.Detail.details]
        for _ in 0..<5 where !details.hasFocus { press(.down) }
        XCTAssertTrue(waitForFocus(details))
        press(.select)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Detail.fullDetailsTitle].waitForExistence(timeout: 5))
        try audit(app)
    }

    func test_boxSet() throws {
        let app = launchAtHome()
        openLibraryTile(UITestFixtureIdentity.boxSetID, inLibrary: UITestFixtureIdentity.boxSetsLibraryID, app)
        let member = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "tv.detail.member.")).firstMatch
        XCTAssertTrue(waitForFocus(member, timeout: 10))
        try audit(app)
    }

    func test_playlist() throws {
        let app = launchAtHome()
        openLibraryTile(UITestFixtureIdentity.playlistID, inLibrary: UITestFixtureIdentity.playlistsLibraryID, app)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Detail.play], timeout: 10))
        try audit(app)
    }

    func test_search() throws {
        let app = launchAtHome()
        openRailFromHome(app)
        press(.down)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Sidebar.search]))
        press(.select)
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Quiet")
        XCTAssertTrue(app.buttons[A11yID.TV.Search.result(UITestFixtureIdentity.primaryMovieID)].waitForExistence(timeout: 10))
        try audit(app)
    }

    func test_profile() throws {
        let app = openProfile()
        try audit(app)
    }

    func test_profileAdvanced() throws {
        let app = openProfile()
        pressDown(until: app.buttons[A11yID.TV.Profile.advanced], presses: 16)
        press(.select)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Profile.streamingMode]))
        try audit(app)
    }

    func test_profileSettingsPicker() throws {
        let app = openProfile()
        pressDown(until: app.buttons[A11yID.TV.Profile.nextUpCountdown], presses: 16)
        press(.select)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Profile.option("30")]))
        try audit(app)
    }

    func test_profileQuickConnectApproval() throws {
        let app = openProfile()
        pressDown(until: app.buttons[A11yID.TV.Profile.approveQuickConnect])
        press(.select)
        XCTAssertTrue(app.textFields[A11yID.TV.Profile.quickConnectCode].waitForExistence(timeout: 5))
        try audit(app)
    }

    func test_profileTextPage() throws {
        let app = openProfile()
        pressDown(until: app.buttons[A11yID.TV.Profile.privacyPolicy], presses: 16)
        press(.select)
        XCTAssertTrue(app.descendants(matching: .any)[A11yID.TV.Profile.textPage].waitForExistence(timeout: 5))
        try audit(app)
    }

    private func openProfile() -> XCUIApplication {
        let app = launchAtHome()
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Main.heroPlay], timeout: 10))
        openRailFromHome(app)
        press(.up)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Sidebar.profile]))
        press(.select)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Profile.switchUser]))
        return app
    }

    func test_playerTransport() throws {
        let app = openPlayer(extraArguments: ["-UITestDisableControlAutoHide", "YES"])
        try audit(app)
    }

    func test_playerAccessibleTransport() throws {
        let app = openPlayer(extraArguments: ["-UITestAccessibleTransport", "YES"])
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Player.control("playPause")]))
        try audit(app)
    }

    func test_playerAccessibleTransportPanel() throws {
        let app = openPlayer(extraArguments: ["-UITestAccessibleTransport", "YES"])
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Player.control("playPause")]))
        XCTAssertTrue(moveFocus(to: app.buttons[A11yID.TV.Player.control("info")], pressing: .right, limit: 6))
        press(.select)
        XCTAssertTrue(app.descendants(matching: .any)[A11yID.TV.Player.panel].waitForExistence(timeout: 5))
        try audit(app)
    }

    func test_playerPanel() throws {
        let app = openPlayer(extraArguments: ["-UITestDisableControlAutoHide", "YES"])
        press(.down)
        XCTAssertTrue(waitForPlayerFocus(app, "tab.info"))
        try audit(app)
    }

    func test_playerNextUp() throws {
        let app = launch(scenario: "earlyCredits", seedSession: true)
        waitForHomeThenFirstTile(app)
        press(.right)
        openDetailFromFocusedTile(app)
        press(.select)
        XCTAssertTrue(app.descendants(matching: .any)[A11yID.TV.Player.nextUpCard].waitForExistence(timeout: 10))
        try audit(app)
    }

    func test_playerStats() throws {
        let app = openPlayer(extraArguments: ["-UITestDisableControlAutoHide", "YES", "-showPlaybackStatsButtonEnabled", "YES"])
        press(.up)
        press(.right, times: 3)
        XCTAssertTrue(waitForPlayerFocus(app, "icon.stats"))
        press(.select)
        XCTAssertTrue(app.descendants(matching: .any)[A11yID.TV.Player.statsValue("Codec")].waitForExistence(timeout: 3))
        try audit(app)
    }

    private func audit(_ app: XCUIApplication) throws {
        try app.performAccessibilityAudit(for: Self.auditedTypes) { Self.isKnownAcceptable($0) }
    }

    /// iOS's set (`DionysusPlayerUITests/Journeys/AccessibilityAuditTests`):
    /// the structural checks only, not contrast, Dynamic Type or clipping,
    /// which are design-level and documented there and in TESTING.md.
    static let auditedTypes: XCUIAccessibilityAuditType = [
        .elementDetection,
        .hitRegion,
        .sufficientElementDescription,
        .trait
    ]

    /// `true` to ignore an issue.
    static func isKnownAcceptable(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
        guard let element = issue.element else { return false }

        // Any key on the system keyboard (Search's, the Quick Connect code's):
        // OS chrome, and only the system keyboard produces `.key` elements.
        if element.elementType == .key {
            return true
        }

        // Non-interactive text (captions, metadata, footers). The hit-region
        // minimum is for things a user has to reach; on tvOS nothing is
        // pointed at, and text isn't focusable. Scoped to static text so a
        // real control this small still fails.
        if element.elementType == .staticText || element.elementType == .other {
            return issue.auditType == .hitRegion
        }

        // The player's test-only focus marker (`A11yID.TV.Player.focus`):
        // its label is a fixed id, not prose, and it exists only under the
        // harness.
        if element.identifier == A11yID.TV.Player.focus {
            return true
        }

        return false
    }
}
