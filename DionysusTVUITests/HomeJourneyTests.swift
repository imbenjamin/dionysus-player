import XCTest

final class HomeJourneyTests: TVUITestCase {
    func test_home_opensOnTheHero_withRailsBelow() {
        let app = launchAtHome()
        XCTAssertTrue(app.buttons[A11yID.TV.Main.heroInfo].exists)
        XCTAssertTrue(app.descendants(matching: .any)[A11yID.TV.Main.heroTitle].exists)
        focusFirstRailTile(app)
    }

    /// Leaving the player lands on the title's detail page, over Home, so
    /// Menu there goes back to the hero (Benjamin, 2026-10-04).
    func test_heroPlay_startsPlayback_andLeavingItLandsOnTheDetailPage() {
        let app = launchAtHome()
        press(.select)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Player.elapsed].waitForExistence(timeout: 10))
        press(.menu)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Detail.play]), "The title's detail page, focus on Play")
        XCTAssertFalse(app.staticTexts[A11yID.TV.Player.elapsed].exists)
        XCTAssertTrue(waitForCollapsed(app.buttons[A11yID.TV.Sidebar.home]), "The rail stays collapsed")
        press(.menu)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Main.heroPlay]), "Menu goes back to the hero")
    }

    func test_moreInfo_opensTheDetailPage() {
        let app = launchAtHome()
        press(.right)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Main.heroInfo]))
        press(.select)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Detail.play]))
        press(.menu)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Main.heroInfo]))
    }

    /// Right from More Info pages the hero forward, wrapping to the first
    /// item after the last; Left from Play always opens the rail.
    func test_hero_pagesForwardByHand_wraps_andLeftOpensTheRail() {
        let app = launchAtHome()
        let title = app.descendants(matching: .any)[A11yID.TV.Main.heroTitle]
        let dots = app.descendants(matching: .any)[A11yID.TV.Main.heroDots]
        let first = title.label
        press(.right)
        let info = app.buttons[A11yID.TV.Main.heroInfo]
        XCTAssertTrue(waitForFocus(info))
        press(.right)
        XCTAssertTrue(poll(timeout: 5) { title.label != first }, "Right from More Info shows the next item")
        XCTAssertTrue(waitForFocus(info), "Focus stays on More Info")

        // "Item 2 of N": page on until it reads item 1 again.
        let count = Int(dots.label.split(separator: " ").last ?? "") ?? 0
        XCTAssertGreaterThan(count, 1)
        for _ in 0..<(count - 1) {
            press(.right)
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
        XCTAssertTrue(poll(timeout: 5) { title.label == first }, "After the last item it wraps to the first")

        press(.left)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Main.heroPlay]))
        press(.left)
        XCTAssertTrue(waitForExpanded(app.buttons[A11yID.TV.Sidebar.home]), "Left from Play opens the rail")
    }

    /// The harness freezes ambient motion, so the hero must not move by
    /// itself here; the timer's rules are pinned by `TVHeroPagerTests`.
    func test_hero_staysPut_underTheHarness() {
        let app = launchAtHome()
        let title = app.descendants(matching: .any)[A11yID.TV.Main.heroTitle]
        let first = title.label
        RunLoop.current.run(until: Date().addingTimeInterval(7))
        XCTAssertEqual(title.label, first)
    }

    func test_seeAll_opensAGrid_andMenuReturnsToIt() {
        let app = launchAtHome()
        // Recently Added Movies, the third rail in the fixture's order after
        // Continue Watching and Next Up, always has one. Its See All is the
        // last thing in a lazy row, so it exists only once walked to.
        let seeAll = app.buttons[A11yID.TV.Main.seeAll("Recently Added Movies")]
        focusFirstRailTile(app)
        press(.down, times: 2)
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        for _ in 0..<20 where !(seeAll.exists && seeAll.hasFocus) { press(.right) }
        XCTAssertTrue(waitForFocus(seeAll))
        press(.select)
        XCTAssertTrue(waitForFocus(firstLibraryTile(app)), "See All opens a grid, with the rail still on Home's row")
        XCTAssertTrue(isCollapsed(app.buttons[A11yID.TV.Sidebar.home]))
        press(.menu)
        XCTAssertTrue(waitForFocus(seeAll))
    }

    /// A Libraries tile switches to the library's own page; it doesn't push.
    func test_librariesRail_switchesToTheLibrarysPage() {
        let app = launchAtHome()
        let library = app.buttons[A11yID.TV.Main.library(UITestFixtureIdentity.moviesLibraryID)]
        // Last, below every rail Home discovers as it scrolls.
        for _ in 0..<40 where !library.exists { press(.down) }
        XCTAssertTrue(library.waitForExistence(timeout: 5))
        for _ in 0..<4 where !library.hasFocus { press(.down) }
        XCTAssertTrue(waitForFocus(library))
        press(.select)
        XCTAssertTrue(waitForFocus(firstLibraryTile(app)))
        press(.menu)
        XCTAssertTrue(waitForExpanded(app.buttons[A11yID.TV.Sidebar.library(UITestFixtureIdentity.moviesLibraryID)]),
                      "Menu opens the rail on the library's row: it's a top-level page, not a pushed one")
    }

    func test_failedHome_showsRetry() {
        let app = launch(scenario: "failingHome", seedSession: true)
        let retry = app.buttons[A11yID.TV.Main.retry]
        XCTAssertTrue(retry.waitForExistence(timeout: 15))
        XCTAssertTrue(waitForFocus(retry))
    }
}
