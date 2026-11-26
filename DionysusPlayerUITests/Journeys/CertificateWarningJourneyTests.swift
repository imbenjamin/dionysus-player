import XCTest

/// The changed-certificate warning (#466): the configured server's
/// certificate is refused, and the app asks over everything instead of
/// failing quietly or falling to the login screen. `.changedCertificate`
/// seeds an `https://` server trusting `selfSignedA` while the stub presents
/// `selfSignedB`; `.untrustedCertificate` one trusting nothing.
final class CertificateWarningJourneyTests: UITestCase {
    /// A changed certificate at launch shows the warning, with the trusted
    /// and the presented fingerprints, which differ.
    func testChangedCertificateAtLaunchShowsBothFingerprints() {
        launch(scenario: "changedCertificate")

        let warning = CertificateWarningScreen(app: app)
        warning.awaitShown()
        warning.previousFingerprint.awaitExistence("the trusted certificate's fingerprint")
        warning.newFingerprint.awaitExistence("the new certificate's fingerprint")
        let previous = warning.previousFingerprint.value as? String ?? ""
        let new = warning.newFingerprint.value as? String ?? ""
        XCTAssertFalse(previous.isEmpty, "The trusted fingerprint should be read out in full.")
        XCTAssertFalse(new.isEmpty, "The new fingerprint should be read out in full.")
        XCTAssertNotEqual(previous, new, "The two fingerprints are of different certificates.")
        XCTAssertTrue(warning.trustButton.exists)
        XCTAssertTrue(warning.changeServerButton.exists)
    }

    /// A trust kept by name whose certificate still carries the names but no
    /// longer verifies says so, naming them, rather than calling it a new
    /// certificate; the trusted names stay beside it, and Trust still asks.
    func testALapsedNameTrustSaysTheCertificateIsNoLongerValid() {
        launch(scenario: "lapsedNameCertificate")

        let warning = CertificateWarningScreen(app: app)
        warning.awaitShown()
        warning.message.awaitExistence("the warning's message")
        XCTAssertTrue(warning.message.label.contains("media.dionysus.test"), "Names what it's still for: \(warning.message.label)")
        XCTAssertTrue((warning.previousFingerprint.value as? String ?? "").contains("media.dionysus.test"), "The trusted names")
        warning.newFingerprint.awaitExistence("the certificate's fingerprint")
        warning.trustButton.tap()
        warning.trustConfirmButton.awaitExistence("the confirmation's Trust button")
    }

    /// "Trust New Certificate" asks first; confirmed, the session restarts
    /// under the new certificate and Home loads.
    func testTrustingTheNewCertificateSignsBackIn() {
        launch(scenario: "changedCertificate")

        let warning = CertificateWarningScreen(app: app)
        warning.awaitShown()
        warning.trustButton.tap()
        warning.trustConfirmButton.awaitExistence("the confirmation's Trust button")
        warning.trustConfirmButton.tap()

        warning.awaitGone()
        HomeScreen(app: app).awaitLoaded()
        XCTAssertFalse(app.descendants(matching: .any)[A11yID.State.offline].exists, "Back online once trusted")
    }

    /// "Not Now (Stay Offline)" carries on offline, where Downloads still
    /// work, and doesn't ask again for the same certificate.
    func testNotNowStaysOfflineWithDownloadsReachable() {
        launch(scenario: "changedCertificate")

        let warning = CertificateWarningScreen(app: app)
        warning.awaitShown()
        warning.notNowButton.tap()
        warning.awaitGone()

        TabBar(app: app).downloads.tap()
        DownloadsScreen(app: app).emptyState.awaitExistence("the Downloads tab, reachable offline")

        // A search makes requests the same certificate refuses again.
        TabBar(app: app).search.tap()
        SearchScreen(app: app).search(for: "Signal")
        XCTAssertFalse(
            warning.notNowButton.waitForExistence(timeout: 4),
            "The same certificate isn't asked about again this launch."
        )
    }

    // MARK: - Mid-session (`.certificateChangesMidSession`)

    /// Launches on Home under `selfSignedA`; the stub presents `selfSignedB`
    /// from the first request whose path ends in `switchPath`.
    private func launchChangingCertificate(at switchPath: String) {
        launch(scenario: "certificateChangesMidSession", extraArguments: ["-UITestCertificateSwitchPath", switchPath])
        HomeScreen(app: app).awaitLoaded()
    }

    /// Opens a `dionysus://` link in the running app, accepting the system's
    /// "Open in Dionysus?" prompt if it asks (as `DeepLinkJourneyTests`).
    private func openLink(_ path: String) {
        XCUIDevice.shared.system.open(URL(string: "dionysus://" + path)!)
        let open = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Open"]
        if open.waitForExistence(timeout: 2) { open.tap() }
    }

    /// Refused while the Account sheet is up: the sheet closes and the
    /// warning shows in its place, instead of being refused by UIKit and
    /// left set with nothing on screen.
    func testAWarningRaisedOverASheetReplacesIt() {
        launchChangingCertificate(at: "/QuickConnect/Authorize")
        openLink("quickconnect/approve?code=\(UITestFixtureIdentity.quickConnectApprovableCode)")
        let quickConnect = QuickConnectApprovalScreen(app: app)
        quickConnect.authorizeButton.awaitExistence("Quick Connect's Authorize, in the Account sheet")
        quickConnect.authorizeButton.tap()

        let warning = CertificateWarningScreen(app: app)
        warning.awaitShown()
        warning.previousFingerprint.awaitExistence("the trusted certificate, A")
        XCTAssertFalse(quickConnect.authorizeButton.exists, "The Account sheet was closed for it")

        warning.notNowButton.tap()
        warning.awaitGone()
        XCTAssertFalse(quickConnect.authorizeButton.exists, "The sheet doesn't come back")
    }

    /// Refused while a title plays: nothing covers the player; the warning
    /// shows once it has closed.
    func testAWarningRaisedDuringPlaybackWaitsForThePlayerToClose() {
        launchChangingCertificate(at: "/Sessions/Playing")
        HomeScreen(app: app).openItem(UITestFixtureIdentity.primaryMovieID)
        AssetDetailScreen(app: app).play()
        let player = PlayerScreen(app: app)
        player.awaitControls()

        let warning = CertificateWarningScreen(app: app)
        XCTAssertFalse(warning.notNowButton.waitForExistence(timeout: 4), "Nothing covers the player")
        XCTAssertTrue(player.closeButton.exists, "The player is still up")

        player.close()
        warning.awaitShown()
        warning.previousFingerprint.awaitExistence("the trusted certificate, A")
    }

    /// "Change Server" asks first, as Profile's does, then forgets the server
    /// and returns to server setup.
    func testChangeServerFromTheWarningReturnsToSetup() {
        launch(scenario: "changedCertificate")

        let warning = CertificateWarningScreen(app: app)
        warning.awaitShown()
        warning.changeServerButton.tap()
        warning.changeServerConfirmButton.awaitExistence("the change-server confirmation dialog")
        warning.changeServerConfirmButton.tap()

        warning.awaitGone()
        ServerSetupScreen(app: app).awaitLoaded()
    }

    /// A server with no trust stored whose certificate is refused shows the
    /// setup offer's details over the app, not the login screen; trusting
    /// it (no confirmation, as at setup) signs back in.
    func testUntrustedServerShowsTheOfferInsteadOfLogin() {
        launch(scenario: "untrustedCertificate")

        let warning = CertificateWarningScreen(app: app)
        warning.awaitShown()
        warning.newFingerprint.awaitExistence("the certificate's fingerprint")
        XCTAssertFalse(warning.previousFingerprint.exists, "Nothing was trusted before.")
        XCTAssertFalse(LoginScreen(app: app).fixtureUserTile.exists, "Not the login screen")

        warning.trustButton.tap()
        warning.awaitGone()
        HomeScreen(app: app).awaitLoaded()
    }
}
