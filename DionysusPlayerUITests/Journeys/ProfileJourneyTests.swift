import XCTest

/// Profile coverage: the two destructive account actions reachable through
/// the account card (`ProfileScreen`'s doc comment explains why this
/// stays scoped to just those — the rest of Profile forks by device in a
/// way this suite doesn't yet absorb).
final class ProfileJourneyTests: UITestCase {
    /// The stepper steps 10 ms; Reset shows only off 0 ms.
    func testAudioOffsetStepperAndReset() {
        launch()
        HomeScreen(app: app).awaitLoaded()
        TabBar(app: app).profile.tap()
        ProfileScreen(app: app).openPlaybackSettings()
        let stepper = app.steppers[A11yID.Profile.audioOffsetStepper]
        for _ in 0..<6 where !stepper.isHittable { app.swipeUp() }
        stepper.awaitExistence("the audio offset stepper")
        XCTAssertFalse(app.buttons[A11yID.Profile.audioOffsetReset].exists, "No reset at 0 ms")
        stepper.buttons.element(boundBy: 1).tap() // increment
        stepper.buttons.element(boundBy: 1).tap()
        XCTAssertEqual(stepper.value as? String, "20 milliseconds, audio later")
        app.buttons[A11yID.Profile.audioOffsetReset].tap()
        XCTAssertEqual(stepper.value as? String, "0 milliseconds, in sync")
        app.buttons[A11yID.Profile.audioOffsetReset].awaitDisappearance("Reset, back at 0 ms")
    }

    /// Advanced's Read-Ahead Buffer steps 30 s from 5 min.
    func testReadAheadBufferStepsThirtySeconds() {
        launch()
        HomeScreen(app: app).awaitLoaded()
        TabBar(app: app).profile.tap()
        ProfileScreen(app: app).openPlaybackSettings()
        let advanced = app.buttons[A11yID.Profile.advancedPlaybackLink]
        for _ in 0..<8 where !advanced.isHittable { app.swipeUp() }
        advanced.tap()
        let stepper = app.steppers[A11yID.Profile.readAheadBufferStepper]
        for _ in 0..<4 where !stepper.isHittable { app.swipeUp() }
        stepper.awaitExistence("the Read-Ahead Buffer stepper")
        XCTAssertEqual(stepper.value as? String, "5 minutes", "Five minutes by default")
        stepper.buttons.element(boundBy: 1).tap() // increment
        XCTAssertEqual(stepper.value as? String, "5 minutes, 30 seconds")
        stepper.buttons.element(boundBy: 0).tap()
        stepper.buttons.element(boundBy: 0).tap()
        XCTAssertEqual(stepper.value as? String, "4 minutes, 30 seconds")
    }

    /// Each Spatial Audio toggle shows its layout picker while it's on, at
    /// 7.1.4 first. iOS 26 and later: below it the section is hidden
    /// (`SpatialAudioSupport`).
    func testSpatialAudioTogglesRevealTheirLayoutPickers() throws {
        try skipBelowiOS26ForSpatialAudio()
        launch()
        HomeScreen(app: app).awaitLoaded()
        TabBar(app: app).profile.tap()
        ProfileScreen(app: app).openPlaybackSettings()
        for (toggleID, layoutID) in [
            (A11yID.Profile.spatialAtmosToggle, A11yID.Profile.spatialAtmosLayout),
            (A11yID.Profile.spatialDTSXToggle, A11yID.Profile.spatialDTSXLayout),
        ] {
            let toggle = app.switches[toggleID]
            for _ in 0..<8 where !toggle.isHittable { app.swipeUp() }
            toggle.awaitExistence("the \(toggleID) toggle")
            XCTAssertEqual(toggle.value as? String, "0", "Off by default")
            let picker = app.buttons[layoutID]
            XCTAssertFalse(picker.exists, "No layout while it's off")
            toggle.switches.firstMatch.tap()
            picker.awaitExistence("the \(layoutID) picker")
            XCTAssertTrue(
                "\(picker.value ?? "") \(picker.label)".contains("7.1.4"), "7.1.4 is the default layout"
            )
            toggle.switches.firstMatch.tap()
            picker.awaitDisappearance("the layout picker, toggle off")
        }
    }

    func testQuickConnectApprovesACode() {
        launch()
        HomeScreen(app: app).awaitLoaded()
        TabBar(app: app).profile.tap()

        let quickConnect = ProfileScreen(app: app).openQuickConnect()
        quickConnect.authorize(code: UITestFixtureIdentity.quickConnectApprovableCode)

        quickConnect.successMessage.awaitExistence("the signed-in confirmation")
        quickConnect.doneButton.tap()
        XCTAssertTrue(
            ProfileScreen(app: app).quickConnectRow.waitForExistence(timeout: UITestCase.defaultTimeout),
            "Done should return to the Account screen."
        )
    }

    /// A wrong code (404) explains itself and leaves the field editable, and
    /// the right code then goes through.
    func testWrongQuickConnectCodeCanBeCorrected() {
        launch()
        HomeScreen(app: app).awaitLoaded()
        TabBar(app: app).profile.tap()

        let quickConnect = ProfileScreen(app: app).openQuickConnect()
        quickConnect.authorize(code: "000000")
        quickConnect.errorMessage.awaitExistence("the wrong-code message")

        quickConnect.authorize(code: UITestFixtureIdentity.quickConnectApprovableCode)
        quickConnect.successMessage.awaitExistence("the signed-in confirmation")
    }

    /// Jellyfin's 500 for an already-approved code reaches the user as an
    /// explanation, not a generic failure or a dead screen.
    func testAlreadyUsedQuickConnectCodeShowsAnError() {
        launch()
        HomeScreen(app: app).awaitLoaded()
        TabBar(app: app).profile.tap()

        let quickConnect = ProfileScreen(app: app).openQuickConnect()
        quickConnect.authorize(code: UITestFixtureIdentity.quickConnectUsedCode)

        quickConnect.errorMessage.awaitExistence("the already-used message")
        XCTAssertFalse(quickConnect.successMessage.exists)
    }

    /// No row at all when the server has Quick Connect turned off.
    func testQuickConnectRowHiddenWhenTheServerDisablesIt() {
        launch(scenario: "quickConnectDisabled")
        HomeScreen(app: app).awaitLoaded()
        TabBar(app: app).profile.tap()

        let profile = ProfileScreen(app: app)
        profile.openAccountDetails()
        app.buttons[A11yID.Profile.signOutButton].awaitExistence("the Sign Out row")
        // `/QuickConnect/Enabled` answers immediately under the stub, so a
        // row that was going to appear would have by now.
        XCTAssertFalse(
            profile.quickConnectRow.waitForExistence(timeout: 3),
            "Account shouldn't offer Quick Connect on a server that has it turned off."
        )
    }

    func testSignOutReturnsToLogin() {
        launch()
        HomeScreen(app: app).awaitLoaded()
        TabBar(app: app).profile.tap()

        ProfileScreen(app: app).signOut()

        LoginScreen(app: app).awaitLoaded()
        // The sheet closes before the sign-out runs (`AccountAction`), rather
        // than lingering — tappable — while the app changes behind it.
        XCTAssertFalse(app.descendants(matching: .any)[A11yID.Profile.accountSheet].exists)
    }

    /// Distinct from `AuthJourneyTests.testChangingServerFromLoginReturnsToServerSetup`,
    /// which reaches the same `AppState.changeServer()` from Login instead
    /// — this is the other entry point, reachable while already signed in.
    func testChangeServerFromProfileReturnsToServerSetup() {
        launch()
        HomeScreen(app: app).awaitLoaded()
        TabBar(app: app).profile.tap()

        ProfileScreen(app: app).changeServer()

        ServerSetupScreen(app: app).awaitLoaded()
        XCTAssertFalse(app.descendants(matching: .any)[A11yID.Profile.accountSheet].exists)
    }
}
