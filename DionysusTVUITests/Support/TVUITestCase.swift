import XCTest

/// Launches the TV app against the in-process stub server (the same
/// `UITestHarness` the iOS suite uses) and drives it with the Siri Remote.
@MainActor
class TVUITestCase: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        // Experiment: evaluate queries from XCTest's own accessibility
        // snapshot rather than in the app's automation session, which on
        // CI kept answering with Home after a page had opened.
        UserDefaults.standard.set(true, forKey: "XCTDisableRemoteQueryEvaluation")
    }

    @discardableResult
    func launch(
        scenario: String = "standard",
        seedSession: Bool = false,
        skipsWelcome: Bool = true,
        resetsState: Bool = true,
        extraArguments: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-UITestMode", "YES",
            "-UITestScenario", scenario,
            "-UITestResetState", resetsState ? "YES" : "NO",
            "-UITestDisableAnimations", "YES"
        ] + (skipsWelcome ? ["-onboarding.welcomeCompleted", "YES"] : [])
            + (seedSession ? ["-UITestSeedSession", "YES"] : []) + extraArguments
        app.launch()
        return app
    }

    /// Focus moves asynchronously after a press or a data change, so a bare
    /// `hasFocus` read right after one races it.
    func waitForFocus(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == true"), object: element)
        let focused = XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
        if !focused { attachTree() }
        return focused
    }

    /// Attaches the element tree to the result bundle, for a failed wait.
    func attachTree() {
        let attachment = XCTAttachment(string: XCUIApplication().debugDescription)
        attachment.name = "Element tree"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func press(_ button: XCUIRemote.Button, times: Int = 1) {
        for _ in 0..<times { XCUIRemote.shared.press(button) }
    }
}
