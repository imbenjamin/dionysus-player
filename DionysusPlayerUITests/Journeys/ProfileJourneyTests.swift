import XCTest

/// Profile coverage: the Playback settings, Quick Connect approval, the
/// account actions, and the Downloads and About pages. `ProfileScreen`
/// absorbs the iPad's split layout, where each section is a pane.
final class ProfileJourneyTests: UITestCase {
    /// The stepper steps 10 ms; Reset shows only off 0 ms.
    func testAudioOffsetStepperAndReset() {
        launch()
        HomeScreen(app: app).awaitLoaded()
        TabBar(app: app).profile.tap()
        ProfileScreen(app: app).openPlaybackSettings()
        let stepper = app.steppers[A11yID.Profile.audioOffsetStepper]
        for _ in 0..<6 where !stepper.isHittable { ProfileScreen(app: app).scrollSettings() }
        stepper.awaitExistence("the audio offset stepper")
        XCTAssertFalse(app.buttons[A11yID.Profile.audioOffsetReset].exists, "No reset at 0 ms")
        stepper.buttons.element(boundBy: 1).tap() // increment
        stepper.buttons.element(boundBy: 1).tap()
        XCTAssertEqual(stepper.value as? String, "20 milliseconds, audio later")
        // The stepper can sit at the foot of a short screen (the closed Duo),
        // still hittable, with the list yet to make the row below it.
        let reset = app.buttons[A11yID.Profile.audioOffsetReset]
        for _ in 0..<4 where !reset.isHittable { ProfileScreen(app: app).scrollSettings() }
        reset.tap()
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
        for _ in 0..<8 where !advanced.isHittable { ProfileScreen(app: app).scrollSettings() }
        advanced.tap()
        let stepper = app.steppers[A11yID.Profile.readAheadBufferStepper]
        for _ in 0..<4 where !stepper.isHittable { ProfileScreen(app: app).scrollSettings() }
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
            for _ in 0..<8 where !toggle.isHittable { ProfileScreen(app: app).scrollSettings() }
            toggle.awaitExistence("the \(toggleID) toggle")
            XCTAssertEqual(toggle.value as? String, "0", "Off by default")
            let picker = app.buttons[layoutID]
            XCTAssertFalse(picker.exists, "No layout while it's off")
            toggle.switches.firstMatch.tap()
            // The toggle can sit at the foot of a short pane (the Duo in book
            // pose), with the list yet to make the row below it.
            for _ in 0..<4 where !picker.waitForExistence(timeout: 2) {
                ProfileScreen(app: app).scrollSettings()
            }
            picker.awaitExistence("the \(layoutID) picker")
            XCTAssertTrue(
                "\(picker.value ?? "") \(picker.label)".contains("7.1.4"), "7.1.4 is the default layout"
            )
            toggle.switches.firstMatch.tap()
            picker.awaitDisappearance("the layout picker, toggle off")
        }
    }

    /// The section's footer is one sentence; Learn More opens the rest, the
    /// stall caveat included, in a sheet Done closes.
    func testSpatialAudioLearnMoreOpensAndCloses() throws {
        try skipBelowiOS26ForSpatialAudio()
        launch()
        HomeScreen(app: app).awaitLoaded()
        TabBar(app: app).profile.tap()
        ProfileScreen(app: app).openPlaybackSettings()
        let learnMore = app.buttons[A11yID.Profile.spatialAudioLearnMore]
        for _ in 0..<8 where !learnMore.isHittable { ProfileScreen(app: app).scrollSettings() }
        learnMore.awaitExistence("the Spatial Audio Learn More button")
        learnMore.tap()
        let help = app.descendants(matching: .any)[A11yID.Profile.spatialAudioHelp]
        help.awaitExistence("the About Spatial Audio sheet")
        app.buttons[A11yID.Profile.spatialAudioHelpDone].tap()
        help.awaitDisappearance("the About Spatial Audio sheet, after Done")
        XCTAssertTrue(learnMore.isHittable, "Done returns to the settings")
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

    // MARK: - Downloads settings and About (TQ-11)

    /// Simultaneous Downloads is 3 by default and its slider's far left is
    /// Unlimited; Wi-Fi Only starts on and turns off.
    func testDownloadsSettingsSliderReachesUnlimited() {
        launch()
        HomeScreen(app: app).awaitLoaded()
        TabBar(app: app).profile.tap()
        let settings = ProfileScreen(app: app).openDownloadsSettings()

        let slider = settings.simultaneousSlider.awaitExistence("the Simultaneous Downloads slider")
        XCTAssertEqual(slider.value as? String, "3")
        slider.adjust(toNormalizedSliderPosition: 0)
        XCTAssertEqual(slider.value as? String, "Unlimited")

        let wifiOnly = settings.wifiOnlyToggle
        XCTAssertEqual(wifiOnly.value as? String, "1", "Wi-Fi Only is on by default")
        wifiOnly.switches.firstMatch.tap()
        XCTAssertEqual(wifiOnly.value as? String, "0")
    }

    /// A ladder override shows in Downloads settings' Quality on return; a
    /// cell's reset puts back its default, and Reset All, once confirmed,
    /// every cell's.
    func testQualityLadderOverrideShowsInDownloadsSettingsAndResets() {
        launch()
        HomeScreen(app: app).awaitLoaded()
        TabBar(app: app).profile.tap()
        let settings = ProfileScreen(app: app).openDownloadsSettings()
        let defaultQuality = settings.qualityReading

        let ladder = settings.openQualityLadder()
        let resolution = QualityLadderScreen.defaultResolution
        let field = ladder.revealField(resolution, "normal")
        let defaultKbps = field.value as? String
        XCTAssertFalse(ladder.resetAll.isEnabled, "Nothing to reset yet")

        ladder.type("2000", into: field)
        XCTAssertEqual(field.value as? String, "2000")
        ladder.resetButton(resolution, "normal").awaitExistence("the cell's reset, once overridden")
        ladder.dismissNumberPad(from: field)
        XCTAssertTrue(ladder.resetAll.isEnabled)

        app.navigationBackButton.tap()
        settings.qualityPicker.awaitExistence("Downloads settings, back from the ladder")
        let showsOverride = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in settings.qualityReading != defaultQuality }, object: nil
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [showsOverride], timeout: 5), .completed,
            "Quality should show the override, still \(defaultQuality)"
        )

        settings.openQualityLadder()
        _ = ladder.revealField(resolution, "normal")
        ladder.resetButton(resolution, "normal").tap()
        XCTAssertEqual(field.value as? String, defaultKbps)
        ladder.resetButton(resolution, "normal").awaitDisappearance("the cell's reset, back at its default")
        XCTAssertFalse(ladder.resetAll.isEnabled)

        ladder.type("2000", into: field)
        ladder.dismissNumberPad(from: field)
        ladder.resetAll.tap()
        ladder.resetAllConfirm.awaitExistence("Reset All's confirmation").tap()
        XCTAssertEqual(field.value as? String, defaultKbps)
        XCTAssertFalse(ladder.resetAll.isEnabled)

        app.navigationBackButton.tap()
        settings.qualityPicker.awaitExistence("Downloads settings, after Reset All")
        XCTAssertEqual(settings.qualityReading, defaultQuality)
    }

    /// License opens on the app's own licence, with a heading per bundled
    /// library (`LicenseDocumentTests` checks which).
    func testLicenseShowsTheAppsLicenceAndEachLibrary() {
        launch()
        HomeScreen(app: app).awaitLoaded()
        TabBar(app: app).profile.tap()
        ProfileScreen(app: app).openAboutPage(A11yID.Profile.licenseLink)

        let appLicense = app.staticTexts[A11yID.About.appLicense].awaitExistence("the app's licence")
        XCTAssertTrue(appLicense.label.contains("GNU GENERAL PUBLIC LICENSE"), "The app's own licence (GPLv3) comes first")
        for library in ["AetherEngine", "FFmpeg"] {
            app.staticTexts[A11yID.About.licenseComponent(library)].awaitExistence("the \(library) heading")
        }
    }

    /// Privacy Policy renders the bundled `PRIVACY.md`, not its fallback.
    func testPrivacyPolicyShowsTheBundledPolicy() {
        launch()
        HomeScreen(app: app).awaitLoaded()
        TabBar(app: app).profile.tap()
        ProfileScreen(app: app).openAboutPage(A11yID.Profile.privacyPolicyLink)

        let policy = app.staticTexts[A11yID.About.privacyPolicyText].awaitExistence("the privacy policy")
        // Its first heading, in the document rather than the app's strings.
        XCTAssertTrue(policy.label.contains("Privacy Policy"), "Got: \(policy.label.prefix(80))")
        XCTAssertGreaterThan(policy.label.count, 1_000, "The whole policy, not the unavailable message")
    }
}
