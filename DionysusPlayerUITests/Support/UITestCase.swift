import XCTest

/// Base class for every UI test: owns launching the app into a known state
/// and tearing it down again.
///
/// Every launch goes through `launch(...)` rather than each test assembling
/// its own arguments. Two reasons: the flags below are not optional extras —
/// without the state reset, one test's sign-in silently seeds the next test's
/// "first launch"; without the animation and timer suppression, assertions
/// race a hero carousel that advances on its own and shimmer placeholders
/// that never settle. And keeping them in one place means a new flake
/// mitigation is added once, not thirty times.
/// `@MainActor` because XCUITest's API is: `XCUIApplication`,
/// `XCUIElement` and their queries are all main-actor-isolated in the current
/// SDK, while an `XCTestCase` method is nonisolated by default. Without this
/// every `tap()`, `exists` and query in the suite raises a Swift 6
/// concurrency warning. Subclasses inherit the isolation, so individual test
/// classes do not repeat it.
@MainActor
class UITestCase: XCTestCase {
    /// Generous enough to absorb a cold app launch on a loaded CI runner,
    /// tight enough that a genuinely missing element fails the test rather
    /// than stalling it. The stubbed network contributes no latency of its
    /// own, so anything slower than this is a real problem.
    static let defaultTimeout: TimeInterval = 15

    private(set) var app: XCUIApplication!

    // The `async throws` variants, not the plain ones. An override of
    // `XCTestCase`'s synchronous `setUp()`/`tearDown()` is nonisolated
    // regardless of this class's `@MainActor`, so it cannot touch `app` —
    // these inherit the isolation instead.
    override func setUp() async throws {
        try await super.setUp()
        // A UI test that has already failed one assertion is reporting
        // cascading noise from that point on, not new information.
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        app?.terminate()
        app = nil
        try await super.tearDown()
    }

    /// Launches the app against the stub server.
    ///
    /// - Parameters:
    ///   - scenario: Which fixture set the in-app stub serves. See
    ///     `UITestScenario` in the app target.
    ///   - signedIn: `true` seeds a server and credentials so the app opens
    ///     on Home. `false` leaves it at first-run server setup — which is
    ///     what the auth journeys want, and nothing else does.
    ///   - resetsState: `true` (the default, and what almost every journey
    ///     wants) wipes `UserDefaults`/the Keychain/downloaded artifacts
    ///     before this launch, so one test can never see another's
    ///     leftovers. `false` is for the rare journey that is *about*
    ///     something surviving a relaunch — search history, say — and needs
    ///     a second `launch()` in the same test that doesn't undo the
    ///     first's state on the way in.
    ///   - extraArguments: Appended verbatim, for a test that needs to force
    ///     one of the app's own `@AppStorage` keys.
    @discardableResult
    func launch(
        scenario: String = "standard",
        signedIn: Bool = true,
        resetsState: Bool = true,
        extraArguments: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-UITestMode", "YES",
            "-UITestScenario", scenario,
            "-UITestResetState", resetsState ? "YES" : "NO",
            "-UITestDisableAnimations", "YES",
            "-UITestDisableControlAutoHide", "YES",
            // The app's own settings, forced through `UserDefaults`'
            // argument domain — no harness flag needed, and no app code
            // involved. Both drive continuous animation that would otherwise
            // keep the accessibility tree in motion under every assertion:
            // the hero carousel advances on a timer, and 3D depth runs a
            // CoreMotion-driven `rotation3DEffect`.
            "-heroAutoCarouselEnabled", "NO",
            "-hero3DDepthEnabled", "NO"
        ]
        if signedIn {
            app.launchArguments += ["-UITestSeedSession", "YES"]
        }
        app.launchArguments += extraArguments
        app.launch()
        self.app = app
        return app
    }
}

@MainActor
extension XCUIElement {
    /// `waitForExistence` with this suite's shared timeout and a failure
    /// message that names the element, so a red test says *what* never
    /// appeared rather than just `false is not true`.
    @discardableResult
    func awaitExistence(
        _ description: String,
        timeout: TimeInterval = UITestCase.defaultTimeout,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        XCTAssertTrue(
            waitForExistence(timeout: timeout),
            "Timed out after \(timeout)s waiting for \(description).",
            file: file, line: line
        )
        return self
    }

    /// Waits for the element to go away — the dismissal counterpart to
    /// `awaitExistence`, for asserting a screen actually closed rather than
    /// just that something else appeared on top of it.
    func awaitDisappearance(
        _ description: String,
        timeout: TimeInterval = UITestCase.defaultTimeout,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: self
        )
        let result = XCTWaiter().wait(for: [gone], timeout: timeout)
        XCTAssertEqual(
            result, .completed,
            "Timed out after \(timeout)s waiting for \(description) to disappear.",
            file: file, line: line
        )
    }
}
