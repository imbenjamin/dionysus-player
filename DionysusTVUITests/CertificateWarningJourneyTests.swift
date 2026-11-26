import XCTest

/// The changed-certificate warning (#466) on the Apple TV: a full-screen page
/// over everything, opening on "Not Now (Stay Offline)". `.changedCertificate`
/// seeds an `https://` server trusting `selfSignedA` while the stub presents
/// `selfSignedB`; `.untrustedCertificate` one trusting nothing.
///
/// The Top Shelf mirror that Trust re-writes (`TVRootView`) isn't checked
/// here: nothing the harness exposes can read it from a UI test.
final class CertificateWarningJourneyTests: TVUITestCase {
    private func notNow(_ app: XCUIApplication) -> XCUIElement { app.buttons[A11yID.TV.CertificateWarning.notNow] }
    private func trust(_ app: XCUIApplication) -> XCUIElement { app.buttons[A11yID.TV.CertificateWarning.trust] }
    private func changeServer(_ app: XCUIApplication) -> XCUIElement { app.buttons[A11yID.TV.CertificateWarning.changeServer] }
    private func previous(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[A11yID.TV.CertificateWarning.previousFingerprint]
    }
    private func current(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[A11yID.TV.CertificateWarning.newFingerprint]
    }

    /// Launches signed in under `scenario` and waits for the warning, on Not Now.
    private func launchAtWarning(_ scenario: String) -> XCUIApplication {
        let app = launch(scenario: scenario, seedSession: true)
        XCTAssertTrue(notNow(app).waitForExistence(timeout: 10), "The warning shows at launch")
        XCTAssertTrue(waitForFocus(notNow(app)), "The warning opens on Not Now (Stay Offline)")
        return app
    }

    /// Up from Not Now to `button`, then Select.
    private func choose(_ button: XCUIElement, ups: Int) {
        press(.up, times: ups)
        XCTAssertTrue(waitForFocus(button))
        press(.select)
    }

    func testChangedCertificateAtLaunchShowsBothFingerprints() {
        let app = launchAtWarning("changedCertificate")
        XCTAssertTrue(previous(app).waitForExistence(timeout: 5), "The trusted certificate")
        XCTAssertTrue(current(app).exists, "The new certificate")
        let previousValue = previous(app).value as? String ?? ""
        let currentValue = current(app).value as? String ?? ""
        XCTAssertFalse(previousValue.isEmpty, "The trusted certificate is read out")
        XCTAssertFalse(currentValue.isEmpty, "The new certificate is read out")
        XCTAssertNotEqual(previousValue, currentValue)
        XCTAssertTrue(trust(app).exists)
        XCTAssertTrue(changeServer(app).exists)
    }

    /// A trust kept by name whose certificate still carries the names but no
    /// longer verifies says so, naming them, beside the trusted names.
    func testALapsedNameTrustSaysTheCertificateIsNoLongerValid() {
        let app = launchAtWarning("lapsedNameCertificate")
        let message = app.descendants(matching: .any)[A11yID.TV.CertificateWarning.message]
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertTrue(message.label.contains("media.dionysus.test"), "Names what it's still for: \(message.label)")
        XCTAssertTrue((previous(app).value as? String ?? "").contains("media.dionysus.test"), "The trusted names")
        XCTAssertTrue(current(app).exists, "The certificate")
    }

    /// Trust New Certificate asks first, on Cancel; confirmed, the session
    /// restarts under the new certificate and Home loads, with no Who's
    /// Watching? in between.
    func testTrustingTheNewCertificateSignsBackIn() {
        let app = launchAtWarning("changedCertificate")
        choose(trust(app), ups: 2)
        let cancel = app.buttons[A11yID.TV.confirmationCancel]
        XCTAssertTrue(waitForFocus(cancel, timeout: 10), "The question opens on Cancel")
        choose(app.buttons[A11yID.TV.CertificateWarning.trustConfirm], ups: 1)

        XCTAssertTrue(notNow(app).waitForNonExistence(timeout: 10), "The warning closes")
        let play = app.buttons[A11yID.TV.Main.heroPlay]
        XCTAssertTrue(play.waitForExistence(timeout: 15), "Home loads under the new certificate")
        XCTAssertTrue(waitForFocus(play, timeout: 10), "Focus is on the hero's Play, not the sidebar")
        XCTAssertFalse(app.descendants(matching: .any)[A11yID.TV.Onboarding.whosWatchingTitle].exists)
    }

    /// Not Now (Stay Offline) carries on offline: Home's offline state, which
    /// takes focus, and the same certificate isn't asked about again.
    func testNotNowStaysOfflineWithDownloadsReachable() {
        let app = launchAtWarning("changedCertificate")
        press(.select)

        XCTAssertTrue(notNow(app).waitForNonExistence(timeout: 10), "The warning closes")
        let retry = app.buttons[A11yID.TV.Main.retry]
        XCTAssertTrue(retry.waitForExistence(timeout: 10), "Home's offline state")
        XCTAssertTrue(waitForFocus(retry))

        // Try Again makes requests the same certificate refuses again.
        press(.select)
        XCTAssertFalse(notNow(app).waitForExistence(timeout: 4), "Not asked again for the same certificate")
        XCTAssertTrue(retry.waitForExistence(timeout: 15), "Still Home's offline state")
    }

    // MARK: - Mid-session (`.certificateChangesMidSession`)

    /// Launches on Home under `selfSignedA`; the stub presents `selfSignedB`
    /// from the first request whose path ends in `switchPath`.
    private func launchChangingCertificate(at switchPath: String) -> XCUIApplication {
        let app = launch(
            scenario: "certificateChangesMidSession", seedSession: true,
            extraArguments: ["-UITestCertificateSwitchPath", switchPath]
        )
        let play = app.buttons[A11yID.TV.Main.heroPlay]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFocus(play))
        return app
    }

    /// Refused while a cover is up (Profile's Quick Connect approval): the
    /// cover closes and the warning shows in its place, instead of being
    /// refused by UIKit and left set with nothing on screen.
    func testAWarningRaisedOverACoverReplacesIt() {
        let app = launchChangingCertificate(at: "/QuickConnect/Authorize")
        app.open(URL(string: "dionysus://quickconnect/approve?code=\(UITestFixtureIdentity.quickConnectApprovableCode)")!)
        let authorize = app.buttons[A11yID.TV.Profile.quickConnectAuthorize]
        XCTAssertTrue(authorize.waitForExistence(timeout: 10), "Quick Connect's cover, the code filled in")
        pressDown(until: authorize, presses: 5)
        press(.select)

        XCTAssertTrue(waitForFocus(notNow(app), timeout: 10), "The warning, on Not Now")
        XCTAssertTrue(previous(app).exists, "The trusted certificate, A")
        XCTAssertFalse(authorize.exists, "The Quick Connect cover was closed for it")

        press(.select)
        XCTAssertTrue(notNow(app).waitForNonExistence(timeout: 10), "The warning closes")
        XCTAssertFalse(authorize.exists, "The cover doesn't come back")
    }

    /// Refused while a title plays: nothing covers the player; the warning
    /// shows once it has closed.
    func testAWarningRaisedDuringPlaybackWaitsForThePlayerToClose() {
        let app = openPlayer(
            scenario: "certificateChangesMidSession",
            extraArguments: ["-UITestCertificateSwitchPath", "/Sessions/Playing"]
        )
        XCTAssertFalse(notNow(app).waitForExistence(timeout: 4), "Nothing covers the player")
        XCTAssertTrue(app.staticTexts[A11yID.TV.Player.elapsed].exists || app.descendants(matching: .any)[A11yID.TV.Player.focus].exists,
                      "The player is still up")

        leavePlayer(app)
        XCTAssertTrue(waitForFocus(notNow(app), timeout: 10), "The warning, once the player has gone")
        XCTAssertTrue(previous(app).exists, "The trusted certificate, A")
    }

    /// Change Server asks first, as Profile's does (Cancel focused), then
    /// forgets the server and returns to Find Your Server.
    func testChangeServerFromTheWarningReturnsToSetup() {
        let app = launchAtWarning("changedCertificate")
        choose(changeServer(app), ups: 1)
        let cancel = app.buttons[A11yID.TV.confirmationCancel]
        XCTAssertTrue(waitForFocus(cancel, timeout: 10), "The question opens on Cancel")
        choose(app.buttons[A11yID.TV.CertificateWarning.changeServerConfirm], ups: 1)

        XCTAssertTrue(notNow(app).waitForNonExistence(timeout: 10), "The warning closes")
        XCTAssertTrue(
            app.descendants(matching: .any)[A11yID.TV.Onboarding.findServerTitle].waitForExistence(timeout: 10),
            "Back at Find Your Server"
        )
    }

    /// No trust stored: the setup offer's details over the app, not Who's
    /// Watching?; trusting it (no question, as at setup) loads Home.
    func testUntrustedServerShowsTheOfferInsteadOfLogin() {
        let app = launchAtWarning("untrustedCertificate")
        XCTAssertTrue(current(app).waitForExistence(timeout: 5), "The certificate's details")
        XCTAssertFalse(previous(app).exists, "Nothing was trusted before")
        XCTAssertFalse(app.descendants(matching: .any)[A11yID.TV.Onboarding.whosWatchingTitle].exists)

        choose(trust(app), ups: 2)
        XCTAssertTrue(notNow(app).waitForNonExistence(timeout: 10), "The warning closes")
        XCTAssertTrue(app.buttons[A11yID.TV.Main.heroPlay].waitForExistence(timeout: 15), "Home loads")
    }
}
