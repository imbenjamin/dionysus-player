import XCTest

final class LaunchJourneyTests: TVUITestCase {
    /// A fresh install lands on Find Your Server.
    func test_freshLaunch_showsFindYourServer() {
        let app = launch()
        XCTAssertTrue(app.staticTexts[A11yID.TV.Onboarding.findServerTitle].waitForExistence(timeout: 10))
    }

    /// A first launch opens on the Welcome, with Get Started focused; Select
    /// moves on to Find Your Server, and the Welcome never shows again.
    func test_firstLaunch_showsWelcome_thenGetStartedFindsServers() {
        let app = launch(skipsWelcome: false)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Onboarding.welcomeTitle].waitForExistence(timeout: 10))
        let getStarted = app.buttons[A11yID.TV.Onboarding.getStarted]
        XCTAssertTrue(waitForFocus(getStarted))
        press(.select)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Onboarding.findServerTitle].waitForExistence(timeout: 10))
    }
}
