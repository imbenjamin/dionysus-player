import XCTest

final class PlayerJourneyTests: TVUITestCase {
    /// Play on a detail page opens the player (fake engine under the harness),
    /// Right reaches our handler and skips forward, and Menu dismisses back to
    /// the detail page. It plays the part-watched movie because that is the focused first
    /// tile; later rails are off screen in a lazy stack.
    func test_openPlayer_skipForward_menuDismisses() {
        let app = launch(seedSession: true, extraArguments: ["-UITestDisableControlAutoHide", "YES"])
        waitForHomeThenFirstTile(app)
        let play = openDetailFromFocusedTile(app)
        press(.select)

        let elapsed = app.staticTexts[A11yID.TV.Player.elapsed]
        XCTAssertTrue(elapsed.waitForExistence(timeout: 10))
        guard let before = Self.seconds(elapsed.label) else {
            return XCTFail("Unreadable elapsed label \"\(elapsed.label)\"")
        }
        press(.right)
        let skipped = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let label = (object as? XCUIElement)?.label, let now = Self.seconds(label) else { return false }
                return now >= before + 9
            },
            object: elapsed
        )
        XCTAssertEqual(XCTWaiter().wait(for: [skipped], timeout: 5), .completed, "Right should skip 10s on from \(before)s")

        press(.menu)
        XCTAssertTrue(waitForFocus(play), "Menu returns to the detail page the title was played from")
        XCTAssertFalse(elapsed.exists)
    }

    /// Menu while the item is still loading must stop and dismiss (Review
    /// Focus 4). `slowPlaybackInfo` holds the load; `TVPlaybackSessionTests`
    /// pins that nothing plays afterwards.
    func test_menuDuringLoading_dismisses() {
        let app = launch(scenario: "slowPlaybackInfo", seedSession: true)
        waitForHomeThenFirstTile(app)
        let play = openDetailFromFocusedTile(app)
        press(.select)
        let elapsed = app.staticTexts[A11yID.TV.Player.elapsed]
        XCTAssertTrue(elapsed.waitForExistence(timeout: 10))
        press(.menu)
        XCTAssertTrue(waitForFocus(play), "Menu returns to the detail page the title was played from")
        XCTAssertFalse(elapsed.exists)
    }

    /// The title block sits top-left, and the scrubber and elapsed time are on
    /// screen. The format chip is not: see `TVTransportOverlay.showsFormatChip`.
    func test_transport_showsTitleAndTimes_withoutFormatChip() {
        let app = openPlayer(extraArguments: ["-UITestDisableControlAutoHide", "YES"])
        let title = app.descendants(matching: .any)[A11yID.TV.Player.titleBlock]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        // At the tvOS safe-area edge (80pt sides, 60pt top), not inset past it.
        XCTAssertLessThanOrEqual(title.frame.minY, 70, "The title block sits at the top of the safe area")
        XCTAssertLessThanOrEqual(title.frame.minX, 90, "…and at its left edge")
        XCTAssertTrue(app.staticTexts[A11yID.TV.Player.elapsed].exists)
        XCTAssertTrue(app.descendants(matching: .any)[A11yID.TV.Player.transport].exists)
        // The harness's fake engine reports a Dolby Vision source, so the chip
        // would be drawn if it weren't hidden.
        XCTAssertFalse(app.descendants(matching: .any)[A11yID.TV.Player.formatLabel].exists)
    }

    /// A logo that hasn't arrived shows the title as text, never an empty box
    /// (Review Focus 1). `slowLogoImage` holds every logo past this test.
    func test_titleBlock_fallsBackToTitleText_withoutALogo() {
        let app = openPlayer(scenario: "slowLogoImage", extraArguments: ["-UITestDisableControlAutoHide", "YES"])
        let title = app.descendants(matching: .any)[A11yID.TV.Player.titleBlock]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        // The block's label is set explicitly (a logo is an unlabelled image),
        // so the fallback is observed through the harness's marker, as on iOS.
        let fallback = app.descendants(matching: .any)[A11yID.Media.heroLogoFallbackVisible]
        XCTAssertTrue(fallback.waitForExistence(timeout: 5), "The title text should show while the logo is outstanding")
    }

    /// Play/Pause pauses, and the transport stays up while paused, past the
    /// point it would otherwise have faded.
    func test_playPause_pauses_andTheTransportStaysUp() {
        let app = openPlayer(extraArguments: [])
        let elapsed = app.staticTexts[A11yID.TV.Player.elapsed]
        XCTAssertTrue(elapsed.waitForExistence(timeout: 10))
        press(.playPause)
        Thread.sleep(forTimeInterval: 1)
        let pausedAt = elapsed.label
        // Past `TVTransportChrome.visibleDuration` (4s).
        Thread.sleep(forTimeInterval: 6)
        XCTAssertTrue(elapsed.exists, "The transport should stay up while paused")
        XCTAssertEqual(elapsed.label, pausedAt, "Nothing should play while paused")
    }

    /// Launches signed in, opens the focused first tile's detail page and plays it.
    private func openPlayer(scenario: String = "standard", extraArguments: [String]) -> XCUIApplication {
        let app = launch(scenario: scenario, seedSession: true, extraArguments: extraArguments)
        waitForHomeThenFirstTile(app)
        openDetailFromFocusedTile(app)
        press(.select)
        return app
    }

    /// "1:02:03" or "12:34" in seconds.
    nonisolated private static func seconds(_ label: String) -> Double? {
        let parts = label.split(separator: ":").compactMap { Double($0) }
        guard parts.count >= 2 else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }
}
