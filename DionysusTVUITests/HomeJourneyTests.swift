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

    /// No Libraries rail: the sidebar already lists every library
    /// (Benjamin, 2026-10-05).
    func test_home_hasNoLibrariesRail() {
        let app = launchAtHome()
        let library = app.buttons[A11yID.TV.Main.library(UITestFixtureIdentity.moviesLibraryID)]
        // Down to the bottom of Home, a rail at a time, past every rail it
        // discovers: where the Libraries rail used to be built last.
        for _ in 0..<15 where !library.exists {
            press(.down)
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
        XCTAssertFalse(library.exists, "Home lists no libraries")
    }

    /// Rails keep arriving while the spinner at the bottom is on screen,
    /// however many candidates come up too thin: here every one but Drama's.
    /// The spinner used to load one batch when it appeared and never again,
    /// so an empty batch left it spinning for good.
    func test_moreRails_keepLoading_pastBatchesThatFindNothing() {
        let app = launchAtHome(scenario: "thinDynamicRails")
        let drama = app.descendants(matching: .any)[A11yID.TV.Main.rail("Drama Movies")]
        let deadline = Date().addingTimeInterval(40)
        while !drama.exists, Date() < deadline {
            press(.down)
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        XCTAssertTrue(drama.exists, "The one rail with enough titles arrives")
    }

    func test_failedHome_showsRetry() {
        let app = launch(scenario: "failingHome", seedSession: true)
        let retry = app.buttons[A11yID.TV.Main.retry]
        XCTAssertTrue(retry.waitForExistence(timeout: 15))
        XCTAssertTrue(waitForFocus(retry))
    }
}
