import XCTest

/// What changes on iOS when VoiceOver is running: the controls that only mount
/// under it, and the hero's announcements (TQ-12).
///
/// XCUITest can't turn VoiceOver on, so these launch with
/// `-UITestSimulateVoiceOver`, which makes `VoiceOverEnabled` read `true` and
/// records each announcement where a test can read it
/// (`A11yID.UITest.lastAnnouncement`). Nothing is spoken: what's covered is
/// what the app does when it believes VoiceOver is on, not VoiceOver itself.
final class VoiceOverJourneyTests: UITestCase {
    private static let simulatedVoiceOver = ["-UITestSimulateVoiceOver", "YES"]

    private func openPlayer(scenario: String = "standard", extraArguments: [String] = simulatedVoiceOver) -> PlayerScreen {
        launch(scenario: scenario, extraArguments: extraArguments)
        let home = HomeScreen(app: app)
        home.awaitLoaded()
        home.openItem(UITestFixtureIdentity.primaryMovieID)
        AssetDetailScreen(app: app).play()
        let player = PlayerScreen(app: app)
        player.awaitControls()
        return player
    }

    /// The player's one way back to its controls once they're hidden, since
    /// VoiceOver swipes between elements and never taps the picture. It stays
    /// mounted while the controls are hidden, which is its point.
    func testThePlayersControlsButtonHidesAndBringsBackTheControls() {
        let player = openPlayer()
        let button = player.voiceOverControlsButton
        button.awaitExistence("the VoiceOver-only controls button")

        // Hittability, not existence: XCUITest's snapshot keeps the faded
        // controls although `.accessibilityHidden` takes them out of what
        // VoiceOver reads (idb's tree, 2026-11-08, shows only this button).
        button.tap()
        player.closeButton.awaitHittable(false, "the controls, hidden by the button")
        XCTAssertTrue(button.isHittable, "The button stays while the controls are hidden")

        // Once they're back XCUITest goes on calling them unhittable (on
        // screen, they're there), so the proof is using one: Close, tapped
        // where it is. Were the controls still hidden, the tap would reach
        // the picture and only bring them back.
        button.tap()
        player.closeButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        player.closeButton.awaitDisappearance("the player, closed with its controls back")
    }

    /// The swipe that dismisses Skip Intro isn't a VoiceOver gesture, so a
    /// button beside it does the same.
    func testTheSkipButtonsDismissButtonDismissesIt() {
        let player = openPlayer(scenario: "skipIntro")
        player.skipSegmentButton.awaitExistence("Skip Intro")
        let dismiss = player.skipSegmentDismissButton
        dismiss.awaitExistence("Skip Intro's VoiceOver-only dismiss button")

        dismiss.tap()
        player.skipSegmentButton.awaitDisappearance("Skip Intro, dismissed")
        XCTAssertFalse(dismiss.exists, "Its dismiss button goes with it")
    }

    /// Pressing Next leaves VoiceOver on the button, so the hero says which
    /// item it moved to. The announcement is that item's card label.
    func testTheHerosNextButtonAnnouncesTheItemItMovesTo() {
        launch(extraArguments: Self.simulatedVoiceOver)
        let home = HomeScreen(app: app)
        home.awaitLoaded()
        let next = home.heroNextButton
        next.awaitExistence("the hero's Next button")
        let announcement = home.lastAnnouncement
        announcement.awaitExistence("the harness's announcement probe")
        XCTAssertEqual(announcement.label, "", "Nothing is announced before a press")

        next.tap()
        let first = announcement.awaitLabel(notEqualTo: "", "an announcement after Next")
        XCTAssertTrue(
            home.heroCardLabels.contains(first),
            "The announcement \"\(first)\" is one of the hero's cards: \(home.heroCardLabels)"
        )

        next.tap()
        let second = announcement.awaitLabel(notEqualTo: first, "a new announcement after a second Next")
        XCTAssertTrue(home.heroCardLabels.contains(second), "So is the second, \"\(second)\"")
    }

    /// Pull to refresh isn't a VoiceOver gesture either, so Home's toolbar
    /// gets a Refresh button, and pressing it reloads in place.
    func testHomesRefreshButtonReloadsHome() {
        launch(extraArguments: Self.simulatedVoiceOver)
        let home = HomeScreen(app: app)
        home.awaitLoaded()
        let refresh = home.refreshButton
        refresh.awaitExistence("Home's VoiceOver-only Refresh button")

        refresh.tap()
        home.awaitLoaded()
        refresh.awaitExistence("the Refresh button, back once the refresh ends")
    }

    /// Without VoiceOver none of these controls is mounted, nor the probe.
    func testTheVoiceOverOnlyControlsAreAbsentWithoutVoiceOver() {
        launch(scenario: "skipIntro")
        let home = HomeScreen(app: app)
        home.awaitLoaded()
        home.heroNextButton.awaitExistence("the hero's Next button, shown with auto-advance off")
        XCTAssertFalse(home.refreshButton.exists, "No Refresh button without VoiceOver")
        XCTAssertFalse(home.lastAnnouncement.exists, "No announcement probe without VoiceOver")

        home.openItem(UITestFixtureIdentity.primaryMovieID)
        AssetDetailScreen(app: app).play()
        let player = PlayerScreen(app: app)
        player.awaitControls()
        player.skipSegmentButton.awaitExistence("Skip Intro")
        XCTAssertFalse(player.voiceOverControlsButton.exists, "No controls button without VoiceOver")
        XCTAssertFalse(player.skipSegmentDismissButton.exists, "No dismiss button without VoiceOver")
    }
}

@MainActor
private extension XCUIElement {
    func awaitHittable(
        _ hittable: Bool,
        _ description: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let reached = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == %@", NSNumber(value: hittable)), object: self)
        XCTAssertEqual(
            XCTWaiter().wait(for: [reached], timeout: UITestCase.defaultTimeout), .completed,
            "Timed out waiting for \(description).", file: file, line: line
        )
    }

    /// Waits for the label to differ from `old`, and returns it.
    @discardableResult
    func awaitLabel(
        notEqualTo old: String,
        _ description: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String {
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", old), object: self)
        XCTAssertEqual(
            XCTWaiter().wait(for: [changed], timeout: UITestCase.defaultTimeout), .completed,
            "Timed out waiting for \(description).", file: file, line: line
        )
        return label
    }
}
