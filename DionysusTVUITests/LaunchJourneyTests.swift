import XCTest

final class LaunchJourneyTests: TVUITestCase {
    /// A fresh install lands on Find Your Server.
    func test_freshLaunch_showsFindYourServer() {
        let app = launch()
        XCTAssertTrue(app.staticTexts[A11yID.TV.Onboarding.findServerTitle].waitForExistence(timeout: 10))
    }
}
