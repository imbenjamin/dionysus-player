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
        for id in [A11yID.TV.Profile.approveQuickConnect, A11yID.TV.Profile.signOut, A11yID.TV.Profile.changeServer,
                   A11yID.TV.Profile.followsAppleTVUsers, A11yID.TV.Profile.autoCarousel, A11yID.TV.Profile.nextUpCountdown,
                   A11yID.TV.Profile.chaptersInScrubber, A11yID.TV.Profile.audioOffset, A11yID.TV.Profile.advanced,
                   A11yID.TV.Profile.license,
                   A11yID.TV.Profile.privacyPolicy] {
            pressDownThroughProfile(until: app.buttons[id])
        }
    }

    /// The global offset: − and + step 10 ms, Reset goes back to 0, and the
    /// row shows the value on return.
    func test_audioOffset_pageStepsAndResets() {
        let app = launchAtHome()
        openProfile(app)
        let row = app.buttons[A11yID.TV.Profile.audioOffset]
        pressDownThroughProfile(until: row)
        press(.select)
        let value = app.descendants(matching: .any)[A11yID.TV.Profile.audioOffsetValue]
        XCTAssertTrue(value.waitForExistence(timeout: 5))
        XCTAssertEqual(value.label, "0 milliseconds, in sync")
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Profile.audioOffsetIncrease]))
        press(.select)
        press(.select)
        XCTAssertTrue(poll(timeout: 3) { value.label == "20 milliseconds, audio later" })
        press(.down)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Profile.audioOffsetReset]))
        press(.select)
        XCTAssertTrue(poll(timeout: 3) { value.label == "0 milliseconds, in sync" })
        press(.menu)
        XCTAssertTrue(waitForFocus(row))
        XCTAssertEqual(row.value as? String, "0 milliseconds, in sync")
    }

    /// Holding Select on + repeats the step after a moment, and letting go
    /// stops it; − counts back the same way.
    func test_audioOffset_holdingRepeats() {
        let app = launchAtHome()
        openProfile(app)
        pressDownThroughProfile(until: app.buttons[A11yID.TV.Profile.audioOffset])
        press(.select)
        let value = app.descendants(matching: .any)[A11yID.TV.Profile.audioOffsetValue]
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Profile.audioOffsetIncrease]))
        XCUIRemote.shared.press(.select, forDuration: 2)
        let held = Self.milliseconds(value.label)
        XCTAssertGreaterThanOrEqual(held, 60, "A two-second hold steps more than once: \(value.label)")
        sleep(1)
        XCTAssertEqual(Self.milliseconds(value.label), held, "Letting go stops the repeat")
        press(.left)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Profile.audioOffsetDecrease]))
        XCUIRemote.shared.press(.select, forDuration: 2)
        XCTAssertLessThan(Self.milliseconds(value.label), held - 30, "Holding − counts back: \(value.label)")
    }

    /// "40 milliseconds, audio later" → 40; "audio earlier" is negative.
    private static func milliseconds(_ spoken: String) -> Int {
        let number = Int(spoken.prefix { $0.isNumber }) ?? 0
        return spoken.contains("earlier") ? -number : number
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

    /// Spatial Audio's toggle shows its layout row, which picks from the
    /// format's layouts, 7.1.4 first chosen.
    func test_spatialAudio_toggleRevealsLayout_andPickerChooses() {
        let app = launchAtHome()
        openProfile(app)
        let toggle = app.buttons[A11yID.TV.Profile.spatialAtmos]
        let layoutRow = app.buttons[A11yID.TV.Profile.spatialAtmosLayout]
        pressDownThroughProfile(until: toggle)
        XCTAssertFalse(layoutRow.exists, "No layout while it's off")
        let before = toggle.value as? String
        press(.select)
        XCTAssertTrue(poll(timeout: 3) { toggle.value as? String != before }, "Select flips it")
        XCTAssertTrue(layoutRow.waitForExistence(timeout: 5))
        XCTAssertEqual(layoutRow.value as? String, "7.1.4")
        pressDown(until: layoutRow)
        press(.select)
        let current = app.buttons[A11yID.TV.Profile.option("7.1.4")]
        XCTAssertTrue(current.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForFocus(current), "The current layout takes focus")
        for layout in ["5.1.2", "5.1.4", "7.1.2", "9.1.6"] {
            XCTAssertTrue(app.buttons[A11yID.TV.Profile.option(layout)].exists, "Atmos offers \(layout)")
        }
        let largest = app.buttons[A11yID.TV.Profile.option("9.1.6")]
        pressDown(until: largest)
        press(.select)
        XCTAssertTrue(waitForFocus(layoutRow), "Choosing returns to the row")
        XCTAssertEqual(layoutRow.value as? String, "9.1.6")
    }

    /// DTS:X renders into 7.1.4 and 9.1.6 only, so its picker offers no other.
    func test_spatialAudio_dtsXPickerOffersTwoLayouts() {
        let app = launchAtHome()
        openProfile(app)
        let toggle = app.buttons[A11yID.TV.Profile.spatialDTSX]
        pressDownThroughProfile(until: toggle)
        press(.select)
        let layoutRow = app.buttons[A11yID.TV.Profile.spatialDTSXLayout]
        XCTAssertTrue(layoutRow.waitForExistence(timeout: 5))
        pressDown(until: layoutRow)
        press(.select)
        XCTAssertTrue(app.buttons[A11yID.TV.Profile.option("7.1.4")].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons[A11yID.TV.Profile.option("9.1.6")].exists)
        for layout in ["5.1.2", "5.1.4", "7.1.2"] {
            XCTAssertFalse(app.buttons[A11yID.TV.Profile.option(layout)].exists, "DTS:X can't render \(layout)")
        }
        press(.menu)
        XCTAssertTrue(waitForFocus(layoutRow))
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

    /// Read-Ahead Buffer: 5 min by default, stepped 30 s with − and +, as
    /// Audio Offset is.
    func test_advanced_readAheadBuffer_stepsThirtySeconds() {
        let app = launchAtHome()
        openProfile(app)
        pressDownThroughProfile(until: app.buttons[A11yID.TV.Profile.advanced])
        press(.select)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Profile.streamingMode]))
        let row = app.buttons[A11yID.TV.Profile.readAheadBuffer]
        pressDown(until: row)
        // The row's value is what VoiceOver reads (`spokenValue`).
        XCTAssertEqual(row.value as? String, "5 minutes")
        press(.select)
        let value = app.descendants(matching: .any)[A11yID.TV.Profile.readAheadBufferValue]
        XCTAssertTrue(value.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Profile.readAheadBufferIncrease]), "The page opens on +")
        XCTAssertFalse(app.buttons[A11yID.TV.Profile.readAheadBufferReset].isEnabled, "Nothing to reset at 5 min")
        press(.select)
        XCTAssertTrue(poll(timeout: 3) { value.label == "5 minutes, 30 seconds" })
        press(.left)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Profile.readAheadBufferDecrease]))
        press(.select)
        press(.select)
        XCTAssertTrue(poll(timeout: 3) { value.label == "4 minutes, 30 seconds" })
        press(.menu)
        XCTAssertTrue(waitForFocus(row))
        XCTAssertEqual(row.value as? String, "4 minutes, 30 seconds")
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

    /// The Spatial Audio section's About row opens its page, which Menu
    /// closes back onto the row.
    func test_spatialAudioAbout_opens_andMenuReturns() {
        let app = launchAtHome()
        openProfile(app)
        let about = app.buttons[A11yID.TV.Profile.spatialAudioAbout]
        pressDownThroughProfile(until: about)
        press(.select)
        XCTAssertTrue(app.descendants(matching: .any)[A11yID.TV.Profile.textPage].waitForExistence(timeout: 5))
        press(.menu)
        XCTAssertTrue(waitForFocus(about))
    }

    /// Sign Out sits above Change Server (Benjamin, 2026-10-05): the
    /// account's own action before the household's.
    func test_signOut_comesBeforeChangeServer() {
        let app = launchAtHome()
        openProfile(app)
        let signOut = app.buttons[A11yID.TV.Profile.signOut]
        let changeServer = app.buttons[A11yID.TV.Profile.changeServer]
        pressDownThroughProfile(until: signOut)
        XCTAssertFalse(changeServer.hasFocus)
        press(.down)
        XCTAssertTrue(waitForFocus(changeServer), "Down from Sign Out reaches Change Server")
    }

    /// Sign Out asks first (Benjamin, 2026-10-05), with Cancel focused, so a
    /// stray Select keeps the account; Cancel returns to the row.
    func test_signOut_asksFirst_andCancelKeepsYouSignedIn() {
        let app = launchAtHome()
        openProfile(app)
        let signOut = app.buttons[A11yID.TV.Profile.signOut]
        pressDownThroughProfile(until: signOut)
        press(.select)
        let confirm = app.buttons[A11yID.TV.Profile.signOutConfirm]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertFalse(confirm.hasFocus, "Cancel, not the destructive action, takes focus")
        press(.select)
        XCTAssertTrue(waitForFocus(signOut), "Cancel returns to the row, still signed in")
    }

    /// Sign Out forgets the account: Who's Watching? lists it as an ordinary
    /// server user again, not as a remembered one.
    func test_signOut_forgetsTheAccount() {
        let app = launchAtHome()
        openProfile(app)
        let signOut = app.buttons[A11yID.TV.Profile.signOut]
        pressDownThroughProfile(until: signOut)
        press(.select)
        let confirm = app.buttons[A11yID.TV.Profile.signOutConfirm]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        press(.up)
        XCTAssertTrue(waitForFocus(confirm))
        press(.select)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Onboarding.whosWatchingTitle].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)[A11yID.TV.Onboarding.user(UITestFixtureIdentity.userID)].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)[A11yID.TV.Onboarding.rememberedUser(UITestFixtureIdentity.userID)].exists)
    }

    /// A row is labelled by its title alone, its setting the value: the
    /// button's label joined both, so VoiceOver read the value twice
    /// ("Chapters in Scrubber, On, On"; M5).
    func test_row_isLabelledByItsTitleAlone() {
        let app = launchAtHome()
        openProfile(app)
        for id in [A11yID.TV.Profile.autoCarousel, A11yID.TV.Profile.nextUpCountdown] {
            let row = app.buttons[id]
            pressDownThroughProfile(until: row)
            let value = row.value as? String ?? ""
            XCTAssertFalse(value.isEmpty)
            XCTAssertFalse(row.label.contains(value), "\(row.label) doesn't repeat \(value)")
        }
    }

    /// The countdown's value is read as its picker reads the choice ("30
    /// seconds"), not as the row shows it ("30s"; M5).
    func test_countdownRow_readsItsValueAsThePickerDoes() {
        let app = launchAtHome()
        openProfile(app)
        let row = app.buttons[A11yID.TV.Profile.nextUpCountdown]
        pressDownThroughProfile(until: row)
        let value = row.value as? String
        press(.select)
        let current = app.buttons[A11yID.TV.Profile.option("30")]
        XCTAssertTrue(current.waitForExistence(timeout: 5))
        XCTAssertEqual(value, current.label)
    }

    /// Each section is a container named for its heading, so VoiceOver says
    /// it on the way in: the heading alone, a header, was never read (M5).
    func test_sections_areNamedForTheirHeadings() {
        let app = launchAtHome()
        openProfile(app)
        for section in ["account", "appleTVUsers", "appearance", "playback", "about"] {
            let group = app.otherElements[A11yID.TV.Profile.section(section)]
            let heading = app.staticTexts[A11yID.TV.Profile.sectionHeading(section)]
            XCTAssertTrue(group.exists, "\(section) is one container")
            XCTAssertTrue(heading.exists)
            // The heading is drawn in capitals (`textCase`), which its label
            // takes too.
            XCTAssertEqual(group.label.localizedLowercase, heading.label.localizedLowercase, "\(section) is named for its heading")
        }
    }

    /// A picker's choices and Advanced's rows are named for the page's
    /// title, which, a header, was never read as it opened (M5).
    func test_pickerAndAdvanced_areNamedForTheirTitles() {
        let app = launchAtHome()
        openProfile(app)
        let row = app.buttons[A11yID.TV.Profile.nextUpCountdown]
        pressDownThroughProfile(until: row)
        press(.select)
        let options = app.otherElements[A11yID.TV.Profile.pickerOptions]
        XCTAssertTrue(options.waitForExistence(timeout: 5))
        XCTAssertEqual(options.label, app.staticTexts[A11yID.TV.Profile.pageTitle].label)
        press(.menu)
        XCTAssertTrue(waitForFocus(row))

        let advanced = app.buttons[A11yID.TV.Profile.advanced]
        pressDownThroughProfile(until: advanced)
        press(.select)
        let rows = app.otherElements[A11yID.TV.Profile.advancedRows]
        XCTAssertTrue(rows.waitForExistence(timeout: 5))
        XCTAssertEqual(rows.label, app.staticTexts[A11yID.TV.Profile.pageTitle].label)
    }
}
