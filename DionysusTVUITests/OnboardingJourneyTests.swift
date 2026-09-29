import XCTest

final class OnboardingJourneyTests: TVUITestCase {
    /// Discovery lists the stub server with default focus on it, so one Select
    /// connects; the stub's public user list then shows, and choosing the
    /// passwordless user (second in the list, after one with a password) signs
    /// straight in.
    func test_selectDiscoveredServer_thenUser_reachesMain() {
        let app = launch()
        let server = app.buttons[A11yID.TV.Onboarding.serverRow(UITestFixtureIdentity.discoveredServerID)]
        XCTAssertTrue(server.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFocus(server), "The first discovered server must take default focus")
        press(.select)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Onboarding.whosWatchingTitle].waitForExistence(timeout: 10))
        let user = app.buttons[A11yID.TV.Onboarding.user(UITestFixtureIdentity.passwordlessUserID)]
        XCTAssertTrue(user.waitForExistence(timeout: 5))
        press(.right)
        XCTAssertTrue(waitForFocus(user))
        press(.select)
        let main = app.descendants(matching: .any)[A11yID.TV.Main.root].waitForExistence(timeout: 10)
        if !main { attachTree() }
        XCTAssertTrue(main)
    }
}
