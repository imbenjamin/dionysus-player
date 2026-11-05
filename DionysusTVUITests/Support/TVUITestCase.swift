import XCTest

/// Launches the TV app against the in-process stub server (the same
/// `UITestHarness` the iOS suite uses) and drives it with the Siri Remote.
@MainActor
class TVUITestCase: XCTestCase {
    // Synchronous, never `async`: with `continueAfterFailure = false`, an
    // async override stops the test plan's retries (see `UITestCase`).
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
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

    /// Waits for a label that was changing (the elapsed time of a player that
    /// was just paused) to hold still, and returns it. The label ticks once a
    /// second, so a quiet spell a little longer than that means it stopped.
    /// Replaces a fixed `sleep(1)` after a pause: it ends the moment the
    /// label is steady, and fails with the tree attached if it never is.
    func steadyLabel(of element: XCUIElement, quietFor quiet: TimeInterval = 1.3, timeout: TimeInterval = 8) -> String {
        var last = element.label
        var since = Date()
        _ = poll(timeout: timeout) {
            let now = element.label
            if now != last { last = now; since = Date() }
            return Date().timeIntervalSince(since) >= quiet
        }
        return last
    }

    func press(_ button: XCUIRemote.Button, times: Int = 1) {
        for _ in 0..<times { XCUIRemote.shared.press(button) }
    }
}
