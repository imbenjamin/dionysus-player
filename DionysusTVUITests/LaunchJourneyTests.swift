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

    /// A slow sign-in holds the splash: its spinner appears after three
    /// seconds, and the splash gives way to Home once signed in, never stuck.
    func test_slowSessionRestore_showsTheSplashSpinner_thenHome() {
        let app = launch(scenario: "slowSignIn", seedSession: true)
        let spinner = app.descendants(matching: .any)[A11yID.TV.Onboarding.splashSpinner]
        XCTAssertTrue(spinner.waitForExistence(timeout: 6))
        XCTAssertFalse(app.buttons[A11yID.TV.Main.heroPlay].exists)
        XCTAssertTrue(app.buttons[A11yID.TV.Main.heroPlay].waitForExistence(timeout: 15))
        XCTAssertFalse(spinner.exists)
    }
}
