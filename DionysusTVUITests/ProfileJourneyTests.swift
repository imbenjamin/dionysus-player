import XCTest

/// Profile: who is signed in, the versions, and every setting as a row.
final class ProfileJourneyTests: TVUITestCase {
    private func openProfile(_ app: XCUIApplication) {
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Main.heroPlay], timeout: 10))
        openRailFromHome(app)
        press(.up)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Sidebar.profile]))
        press(.select)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Profile.switchUser]), "Profile opens with focus on Switch User")
    }

    /// Profile has more rows than a sidebar.
    private func pressDownThroughProfile(until element: XCUIElement) {
        pressDown(until: element, presses: 16)
    }

    func test_profile_showsWhoIsSignedIn_andTheVersions() {
        let app = launchAtHome()
        openProfile(app)
        XCTAssertEqual(app.staticTexts[A11yID.TV.Profile.name].label, UITestFixtureIdentity.username)
        // The server and its address are one element (not static text).
        XCTAssertEqual(app.descendants(matching: .any)[A11yID.TV.Profile.server].label, UITestFixtureIdentity.serverName)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Profile.version].label.contains("AetherEngine"))
    }

    func test_everySection_isReachable() {
        let app = launchAtHome()
        openProfile(app)
        for id in [A11yID.TV.Profile.approveQuickConnect, A11yID.TV.Profile.changeServer, A11yID.TV.Profile.signOut,
                   A11yID.TV.Profile.followsAppleTVUsers, A11yID.TV.Profile.autoCarousel, A11yID.TV.Profile.nextUpCountdown,
                   A11yID.TV.Profile.chaptersInScrubber, A11yID.TV.Profile.advanced, A11yID.TV.Profile.license,
                   A11yID.TV.Profile.privacyPolicy] {
            pressDownThroughProfile(until: app.buttons[id])
        }
    }

    /// Select on a value row cycles its value.
    func test_autoCarousel_toggles() {
        let app = launchAtHome()
        openProfile(app)
        let row = app.buttons[A11yID.TV.Profile.autoCarousel]
        pressDownThroughProfile(until: row)
        let before = row.value as? String
        press(.select)
        XCTAssertTrue(poll(timeout: 5) { (row.value as? String) != before })
    }

    func test_advanced_opens_andMenuReturnsToItsRow() {
        let app = launchAtHome()
        openProfile(app)
        let advanced = app.buttons[A11yID.TV.Profile.advanced]
        pressDownThroughProfile(until: advanced)
        // A row that opens a page shows no value, only a chevron
        // (Benjamin, 2026-10-05): Advanced holds more than one setting.
        XCTAssertEqual(advanced.value as? String ?? "", "")
        press(.select)
        let mode = app.buttons[A11yID.TV.Profile.streamingMode]
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForFocus(mode))
        XCTAssertTrue(app.buttons[A11yID.TV.Profile.subtitleStyling].exists)
        XCTAssertTrue(app.buttons[A11yID.TV.Profile.statsButton].exists)
        press(.menu)
        XCTAssertTrue(waitForFocus(advanced))
    }

    /// Direct Play Always has no bitrate to cap, so its row goes, and comes
    /// back with Allow Transcoding.
    /// A setting with more than two choices opens a page listing them all
    /// (Benjamin, 2026-10-05), focus on the current one; Select picks and
    /// returns to the row.
    func test_nextEpisodeCountdown_picksFromAList() {
        let app = launchAtHome()
        openProfile(app)
        let row = app.buttons[A11yID.TV.Profile.nextUpCountdown]
        pressDownThroughProfile(until: row)
        let before = row.value as? String
        press(.select)
        let current = app.buttons[A11yID.TV.Profile.option("30")]
        XCTAssertTrue(current.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForFocus(current), "The current choice takes focus")
        XCTAssertTrue(current.isSelected, "The current choice is marked")
        for seconds in ["0", "15", "45", "60"] {
            XCTAssertTrue(app.buttons[A11yID.TV.Profile.option(seconds)].exists, "Every choice is listed (\(seconds))")
        }
        let sixty = app.buttons[A11yID.TV.Profile.option("60")]
        pressDown(until: sixty)
        press(.select)
        XCTAssertTrue(waitForFocus(row), "Choosing returns to the row")
        XCTAssertNotEqual(row.value as? String, before)
        XCTAssertFalse(sixty.exists)
    }

    /// Menu leaves the list without changing the setting.
    func test_picker_menuLeavesTheSettingAsItWas() {
        let app = launchAtHome()
        openProfile(app)
        let row = app.buttons[A11yID.TV.Profile.nextUpCountdown]
        pressDownThroughProfile(until: row)
        let before = row.value as? String
        press(.select)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Profile.option("30")]))
        press(.down)
        press(.menu)
        XCTAssertTrue(waitForFocus(row))
        XCTAssertEqual(row.value as? String, before)
    }

    /// Direct Play Always has no bitrate to cap, so its row goes, and comes
    /// back with Allow Transcoding.
    func test_advanced_streamingMode_hidesTheBitrateRow() {
        let app = launchAtHome()
        openProfile(app)
        pressDownThroughProfile(until: app.buttons[A11yID.TV.Profile.advanced])
        press(.select)
        let mode = app.buttons[A11yID.TV.Profile.streamingMode]
        let bitrate = app.buttons[A11yID.TV.Profile.maxBitrate]
        XCTAssertTrue(waitForFocus(mode))
        XCTAssertTrue(bitrate.exists, "Allow Transcoding by default")
        press(.select)
        let direct = app.buttons[A11yID.TV.Profile.option(StreamDecisionModeID.directPlayAlways)]
        XCTAssertTrue(direct.waitForExistence(timeout: 5))
        press(.up)
        XCTAssertTrue(waitForFocus(direct), "Listed first, above the current choice")
        press(.select)
        XCTAssertTrue(waitForFocus(mode))
        XCTAssertTrue(poll(timeout: 5) { !bitrate.exists })
        press(.select)
        let transcoding = app.buttons[A11yID.TV.Profile.option(StreamDecisionModeID.allowTranscoding)]
        XCTAssertTrue(transcoding.waitForExistence(timeout: 5))
        press(.down)
        XCTAssertTrue(waitForFocus(transcoding))
        press(.select)
        XCTAssertTrue(bitrate.waitForExistence(timeout: 5))
    }

    /// `StreamDecisionMode`'s raw values (the UI-test target can't see the
    /// app's types).
    private enum StreamDecisionModeID {
        static let directPlayAlways = "directPlayAlways"
        static let allowTranscoding = "allowTranscoding"
    }

    func test_approveQuickConnect_authorizesACode() {
        let app = launchAtHome()
        openProfile(app)
        let approve = app.buttons[A11yID.TV.Profile.approveQuickConnect]
        pressDownThroughProfile(until: approve)
        press(.select)
        let field = app.textFields[A11yID.TV.Profile.quickConnectCode]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForFocus(field))
        press(.select)
        field.typeText(UITestFixtureIdentity.quickConnectApprovableCode)
        press(.menu)
        let authorize = app.buttons[A11yID.TV.Profile.quickConnectAuthorize]
        pressDownThroughProfile(until: authorize)
        press(.select)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Profile.quickConnectMessage].waitForExistence(timeout: 10))
        press(.menu)
        XCTAssertTrue(waitForFocus(approve), "Menu returns to the row")
    }

    func test_quickConnectOff_hidesTheRow() {
        let app = launchAtHome(scenario: "quickConnectDisabled")
        openProfile(app)
        XCTAssertTrue(app.buttons[A11yID.TV.Profile.changeServer].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons[A11yID.TV.Profile.approveQuickConnect].exists)
    }

    func test_license_scrolls_andMenuReturns() {
        let app = launchAtHome()
        openProfile(app)
        let license = app.buttons[A11yID.TV.Profile.license]
        pressDownThroughProfile(until: license)
        press(.select)
        let page = app.descendants(matching: .any)[A11yID.TV.Profile.textPage]
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        press(.down, times: 3)
        press(.menu)
        XCTAssertTrue(waitForFocus(license))
    }

    func test_privacyPolicy_opens_andMenuReturns() {
        let app = launchAtHome()
        openProfile(app)
        let privacy = app.buttons[A11yID.TV.Profile.privacyPolicy]
        pressDownThroughProfile(until: privacy)
        press(.select)
        XCTAssertTrue(app.descendants(matching: .any)[A11yID.TV.Profile.textPage].waitForExistence(timeout: 5))
        press(.menu)
        XCTAssertTrue(waitForFocus(privacy))
    }

    /// Sign Out forgets the account: Who's Watching? lists it as an ordinary
    /// server user again, not as a remembered one.
    func test_signOut_forgetsTheAccount() {
        let app = launchAtHome()
        openProfile(app)
        let signOut = app.buttons[A11yID.TV.Profile.signOut]
        pressDownThroughProfile(until: signOut)
        press(.select)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Onboarding.whosWatchingTitle].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)[A11yID.TV.Onboarding.user(UITestFixtureIdentity.userID)].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)[A11yID.TV.Onboarding.rememberedUser(UITestFixtureIdentity.userID)].exists)
    }
}
