import XCTest

/// Launches the TV app against the in-process stub server (the same
/// `UITestHarness` the iOS suite uses) and drives it with the Siri Remote.
class TVUITestCase: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @discardableResult
    func launch(scenario: String = "standard", seedSession: Bool = false, extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-UITestMode", "YES",
            "-UITestScenario", scenario,
            "-UITestResetState", "YES",
            "-UITestDisableAnimations", "YES",
            "-onboarding.welcomeCompleted", "YES"
        ] + (seedSession ? ["-UITestSeedSession", "YES"] : []) + extraArguments
        app.launch()
        return app
    }

    func press(_ button: XCUIRemote.Button, times: Int = 1) {
        for _ in 0..<times { XCUIRemote.shared.press(button) }
    }
}
