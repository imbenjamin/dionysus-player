import XCTest

/// Getting through onboarding.
extension TVUITestCase {
    /// From server setup: Select on the discovered stub server, which takes
    /// default focus, then wait for Who's Watching?.
    func connectToDiscoveredServer(_ app: XCUIApplication) {
        let server = app.buttons[A11yID.TV.Onboarding.serverRow(UITestFixtureIdentity.discoveredServerID)]
        XCTAssertTrue(server.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFocus(server), "The first discovered server must take default focus")
        press(.select)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Onboarding.whosWatchingTitle].waitForExistence(timeout: 10))
    }

    /// From server setup: Select on the stub's HTTPS server, whose certificate
    /// every request fails until it's trusted, which offers trust in it
    /// (#466) with the plain-HTTP fallback (#429) as the second choice.
    func selectUnverifiableHTTPSServer(_ app: XCUIApplication) {
        let https = app.buttons[A11yID.TV.Onboarding.serverRow(UITestFixtureIdentity.serverSystemID)]
        XCTAssertTrue(https.waitForExistence(timeout: 10))
        for _ in 0..<3 where !https.hasFocus { press(.down) }
        XCTAssertTrue(waitForFocus(https))
        press(.select)
    }

    /// Selects the stub's HTTPS server and waits for its trust offer, on
    /// Cancel.
    func openCertificateTrustOffer(_ app: XCUIApplication) {
        selectUnverifiableHTTPSServer(app)
        XCTAssertTrue(
            waitForFocus(app.buttons[A11yID.TV.Onboarding.certificateTrustCancel], timeout: 10),
            "The trust offer opens on Cancel"
        )
    }

    /// Through the trust offer's Use Unencrypted HTTP, into the HTTP
    /// fallback (#429).
    func chooseUnencryptedHTTP(_ app: XCUIApplication) {
        openCertificateTrustOffer(app)
        let http = app.buttons[A11yID.TV.Onboarding.certificateTrustHTTP]
        press(.up)
        XCTAssertTrue(waitForFocus(http))
        press(.select)
    }
}
