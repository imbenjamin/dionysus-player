import XCTest

/// `dionysus://` links to places on the Apple TV (#406): Home, Search,
/// Profile and its pages, Quick Connect and a library's grid. Each chooses
/// its sidebar row as a press would, then fills the page as the link asks.
final class DeepLinkPlacesJourneyTests: TVUITestCase {
    private func link(_ path: String) -> URL { URL(string: "dionysus://" + path)! }

    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id]
    }

    /// The toast's text; it's up for a few seconds.
    private func toastMessage(_ app: XCUIApplication) -> String? {
        let toast = any(app, A11yID.Toast.message)
        return toast.waitForExistence(timeout: 10) ? toast.label : nil
    }

    func test_searchLink_runsTheQuery() {
        let app = launchAtHome()
        app.open(link("search?q=Quiet"))
        XCTAssertTrue(any(app, A11yID.TV.Search.result(UITestFixtureIdentity.primaryMovieID)).waitForExistence(timeout: 10))
    }

    func test_profileLink_opensProfile_andHomeLinkReturns() {
        let app = launchAtHome()
        app.open(link("profile"))
        XCTAssertTrue(app.buttons[A11yID.TV.Profile.switchUser].waitForExistence(timeout: 10))
        app.open(link("home"))
        XCTAssertTrue(app.buttons[A11yID.TV.Main.heroPlay].waitForExistence(timeout: 10))
    }

    func test_profileLink_opensTheLicense() {
        let app = launchAtHome()
        app.open(link("profile/about/license"))
        XCTAssertTrue(any(app, A11yID.TV.Profile.textPage).waitForExistence(timeout: 10))
    }

    func test_profileLink_opensAdvancedPlayback() {
        let app = launchAtHome()
        app.open(link("profile/playback/advanced"))
        XCTAssertTrue(any(app, A11yID.TV.Profile.advancedRows).waitForExistence(timeout: 10))
    }

    /// Filled in, not approved: that stays a press of Authorize.
    func test_quickConnectLink_fillsTheCode_withoutApproving() {
        let app = launchAtHome()
        let code = UITestFixtureIdentity.quickConnectApprovableCode
        app.open(link("quickconnect/approve?code=\(code)"))
        let field = app.textFields[A11yID.TV.Profile.quickConnectCode]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertEqual(field.value as? String, code)
        XCTAssertTrue(app.buttons[A11yID.TV.Profile.quickConnectAuthorize].isEnabled)
        let message = any(app, A11yID.TV.Profile.quickConnectMessage)
        XCTAssertFalse(message.exists && message.label.contains("signed in"), "Not approved by the link")
    }

    /// Genre Action and Favorites leave `Iron Meridian` alone, as choosing
    /// both pills does.
    func test_libraryLink_opensTheGrid_filtered() {
        let app = launchAtHome()
        app.open(link("library/\(UITestFixtureIdentity.moviesLibraryID)?genre=Action&filter=favorites"))
        XCTAssertTrue(app.buttons["tv.library.tile.\(UITestFixtureIdentity.movieID(4))"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["tv.library.tile.\(UITestFixtureIdentity.partWatchedMovieID)"].exists)
        XCTAssertTrue(app.buttons[A11yID.TV.Library.resetFilters].exists, "Reset, for the link's filters")
    }

    func test_libraryLink_forAnUnknownLibrary_saysSo() {
        let app = launchAtHome()
        app.open(link("library/\(UITestFixtureIdentity.missingItemID)"))
        XCTAssertEqual(toastMessage(app), "This library can't be found.")
    }

    func test_downloadsLink_landsOnHome_andSaysWhy() {
        let app = launchAtHome()
        app.open(link("downloads"))
        XCTAssertEqual(toastMessage(app), "Downloads aren't on Apple TV.")
        XCTAssertTrue(app.buttons[A11yID.TV.Main.heroPlay].exists)
    }
}
