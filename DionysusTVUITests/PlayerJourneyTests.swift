import XCTest

final class PlayerJourneyTests: TVUITestCase {
    /// Select on a tile opens the player (fake engine under the harness), Right
    /// reaches our handler and skips forward, and Menu dismisses back to the
    /// tile. It plays the part-watched movie because that is the focused first
    /// tile; later rails are off screen in a lazy stack.
    func test_openPlayer_skipForward_menuDismisses() {
        let app = launch(seedSession: true, extraArguments: ["-UITestDisableControlAutoHide", "YES"])
        let tile = app.buttons[A11yID.TV.Main.tile(UITestFixtureIdentity.partWatchedMovieID)]
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFocus(tile))
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
        XCTAssertTrue(waitForFocus(tile))
        XCTAssertFalse(elapsed.exists)
    }

    /// Menu while the item is still loading must stop and dismiss (Review
    /// Focus 4). `slowPlaybackInfo` holds the load; `TVPlaybackSessionTests`
    /// pins that nothing plays afterwards.
    func test_menuDuringLoading_dismisses() {
        let app = launch(scenario: "slowPlaybackInfo", seedSession: true)
        let tile = app.buttons[A11yID.TV.Main.tile(UITestFixtureIdentity.partWatchedMovieID)]
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFocus(tile))
        press(.select)
        let elapsed = app.staticTexts[A11yID.TV.Player.elapsed]
        XCTAssertTrue(elapsed.waitForExistence(timeout: 10))
        press(.menu)
        XCTAssertTrue(waitForFocus(tile))
        XCTAssertFalse(elapsed.exists)
    }

    /// "1:02:03" or "12:34" in seconds.
    nonisolated private static func seconds(_ label: String) -> Double? {
        let parts = label.split(separator: ":").compactMap { Double($0) }
        guard parts.count >= 2 else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }
}
