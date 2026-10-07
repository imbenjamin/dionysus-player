import XCTest

/// Detail pages inside the shell: a tile opens one beside the rail, Menu pops
/// it back to the tile, and a More Like This chain past the keep-alive cap
/// unwinds one page at a time.
final class DetailJourneyTests: TVUITestCase {
    func test_tile_opensItsDetailPage_besideTheRail_andMenuReturnsToTheTile() {
        let app = launchAtHomeTile()
        let tile = app.buttons[A11yID.TV.Main.tile(UITestFixtureIdentity.partWatchedMovieID)]
        openDetailFromFocusedTile(app)
        XCTAssertTrue(isCollapsed(app.buttons[A11yID.TV.Sidebar.home]), "The rail stays beside a detail page")
        XCTAssertTrue(app.buttons[A11yID.TV.Detail.restart].exists, "A part-watched movie offers Restart")

        press(.menu)
        XCTAssertTrue(waitForFocus(tile), "Menu pops the page and focus returns to the tile")
        XCTAssertFalse(app.buttons[A11yID.TV.Detail.play].exists)
        XCTAssertTrue(isCollapsed(app.buttons[A11yID.TV.Sidebar.home]), "Menu popped; it did not open the rail")
    }

    func test_menuOnTheRootPage_stillOpensTheRail() {
        let app = launchAtHomeTile()
        openDetailFromFocusedTile(app)
        press(.menu)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Main.tile(UITestFixtureIdentity.partWatchedMovieID)]))
        // On Home below the hero, Menu first goes back to the hero
        // (Benjamin, 2026-10-07).
        press(.menu)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Main.heroPlay]))
        press(.menu)
        XCTAssertTrue(waitForExpanded(app.buttons[A11yID.TV.Sidebar.home]), "With the path empty, Menu opens the rail")
    }

    func test_play_thenMenu_returnsToTheDetailPage() {
        let app = launchAtHomeTile()
        let play = openDetailFromFocusedTile(app)
        press(.select)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Player.elapsed].waitForExistence(timeout: 10))
        press(.menu)
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        XCTAssertTrue(poll(timeout: 5) { !app.staticTexts[A11yID.TV.Player.elapsed].exists })
        press(.menu)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Main.tile(UITestFixtureIdentity.partWatchedMovieID)]))
    }

    func test_watched_andFavorite_toggle() {
        let app = launchAtHomeTile()
        openDetailFromFocusedTile(app)
        let watched = app.buttons[A11yID.TV.Detail.watched]
        let before = watched.label
        for _ in 0..<3 where !watched.hasFocus { press(.right) }
        XCTAssertTrue(waitForFocus(watched))
        press(.select)
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", before), object: watched)
        XCTAssertEqual(XCTWaiter().wait(for: [changed], timeout: 5), .completed)
    }

    /// Review Focus 2. Six pages deep is past the cap (four live pages), so
    /// the first detail pages are torn down and rebuilt on the way back.
    func test_moreLikeThisChain_pastTheCap_unwindsToTheRootTile() {
        let app = launchAtHomeTile()
        let tile = app.buttons[A11yID.TV.Main.tile(UITestFixtureIdentity.partWatchedMovieID)]
        openDetailFromFocusedTile(app)
        let similar = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "tv.detail.similar."))
        for depth in 2...6 {
            // Down from the actions to More Like This.
            let focusedSimilar = app.buttons.matching(NSPredicate(format: "hasFocus == true AND identifier BEGINSWITH %@", "tv.detail.similar.")).firstMatch
            for _ in 0..<6 where !focusedSimilar.exists { press(.down) }
            XCTAssertTrue(focusedSimilar.waitForExistence(timeout: 5), "Depth \(depth): More Like This is reachable")
            XCTAssertTrue(similar.count > 0)
            press(.select)
            XCTAssertTrue(poll(timeout: 10) { !focusedSimilar.exists && app.buttons[A11yID.TV.Detail.play].hasFocus }, "Depth \(depth): the next page opens on Play")
        }
        // A page kept alive comes back on the More Like This tile it was left
        // from, below its header, so Menu first goes back to its Play and the
        // next pops (Benjamin, 2026-10-07). One rebuilt past the cap opens
        // on Play, its landing view, so one Menu pops it.
        let play = app.buttons[A11yID.TV.Detail.play]
        let focusedSimilar = app.buttons.matching(NSPredicate(format: "hasFocus == true AND identifier BEGINSWITH %@", "tv.detail.similar.")).firstMatch
        press(.menu)
        for depth in stride(from: 5, through: 1, by: -1) {
            // tvOS focuses Play for a moment as a page comes back, before
            // the page puts focus back on the tile it had: let it settle.
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            XCTAssertTrue(poll(timeout: 5) { focusedSimilar.exists || play.hasFocus }, "Back at depth \(depth): focus is on the tile it left from, or on Play")
            XCTAssertTrue(isCollapsed(app.buttons[A11yID.TV.Sidebar.home]), "Back at depth \(depth): the rail did not open")
            if focusedSimilar.exists {
                press(.menu)
                XCTAssertTrue(waitForFocus(play), "Depth \(depth): Menu goes to Play first")
            }
            press(.menu)
        }
        XCTAssertTrue(waitForFocus(tile), "The last Menu lands on the tile the chain started from")
    }

    /// Review Focus 5.
    func test_failedDetail_showsRetry_andMenuPops() {
        let app = launchAtHomeTile(scenario: "failingDetail")
        _ = openMovies(app)
        let failing = app.buttons[A11yID.TV.Library.tile(UITestFixtureIdentity.movieID(3))]
        for _ in 0..<12 where !failing.hasFocus { press(.right) }
        XCTAssertTrue(waitForFocus(failing))
        press(.select)
        let retry = app.buttons[A11yID.TV.Detail.retry]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFocus(retry), "Retry takes focus, so Menu has somewhere to go from")
        press(.menu)
        XCTAssertTrue(waitForFocus(failing))
    }

    /// Down from the actions walks the page a row at a time (Benjamin,
    /// 2026-10-02): Cast & Crew, which can be walked; More Like This; then
    /// Details, which opens the full list.
    func test_down_walksCast_thenMoreLikeThis_thenDetails() {
        let app = launchAtHomeTile()
        openDetailFromFocusedTile(app)
        func focused(_ prefix: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true AND identifier BEGINSWITH %@", prefix)).firstMatch
        }

        press(.down)
        let cast = focused("tv.detail.cast.")
        XCTAssertTrue(cast.waitForExistence(timeout: 5), "Down from the actions lands in Cast & Crew")
        let firstFocused = cast.identifier
        press(.right)
        XCTAssertTrue(poll(timeout: 5) { focused("tv.detail.cast.").identifier != firstFocused }, "The rail can be walked")

        press(.down)
        let similar = focused("tv.detail.similar.")
        XCTAssertTrue(similar.waitForExistence(timeout: 5), "Down again lands in More Like This")

        press(.down)
        let details = app.buttons[A11yID.TV.Detail.details]
        XCTAssertTrue(waitForFocus(details), "Down again reaches Details")
        XCTAssertLessThanOrEqual(details.frame.maxY, app.frame.maxY, "…scrolled wholly on screen")

        // Select opens the full list over the page; Menu closes it.
        press(.select)
        let full = app.staticTexts[A11yID.TV.Detail.fullDetailsTitle]
        XCTAssertTrue(full.waitForExistence(timeout: 5), "Select on Details opens the full list")
        press(.menu)
        XCTAssertTrue(poll(timeout: 5) { !full.exists })
        XCTAssertTrue(details.exists, "Menu closes the list, back on the detail page")
        press(.up)
        XCTAssertTrue(focused("tv.detail.similar.").waitForExistence(timeout: 5), "Up returns to More Like This")
    }

    /// Back up to the actions, the page returns to its starting position:
    /// the whole logo on show, not cut off at the top (Benjamin, 2026-10-02).
    /// Down is pressed the moment the page opens: the start position is the
    /// page's top, not something recorded after a pause.
    func test_upToTheActions_scrollsBackToTheTop() {
        let app = launchAtHomeTile()
        openDetailFromFocusedTile(app)
        let title = app.descendants(matching: .any)[A11yID.TV.Detail.title]
        let startY = title.frame.minY
        press(.down, times: 2)
        XCTAssertTrue(poll(timeout: 5) { !title.exists || title.frame.minY < startY - 100 }, "Moving down scrolls the header away")
        press(.up, times: 2)
        // Up from Cast & Crew lands on whichever action sits beneath the
        // focused person, not necessarily Play.
        let action = app.buttons.matching(NSPredicate(format: "hasFocus == true AND identifier IN %@", [
            A11yID.TV.Detail.play, A11yID.TV.Detail.restart, A11yID.TV.Detail.watched, A11yID.TV.Detail.favorite
        ])).firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 5), "Up twice is back on the action row")
        XCTAssertTrue(poll(timeout: 5) { title.exists && abs(title.frame.minY - startY) < 2 }, "Back at the actions, the page is where it started")
    }

    /// Up from a cast member far to the right of the action row still
    /// reaches it (Benjamin, 2026-10-02): nothing sits directly above.
    func test_upFromAFarCastMember_reachesTheActions() {
        let app = launchAtHomeTile(scenario: "largeCast")
        openDetailFromFocusedTile(app)
        press(.down)
        let cast = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true AND identifier BEGINSWITH %@", "tv.detail.cast.")).firstMatch
        XCTAssertTrue(cast.waitForExistence(timeout: 5))
        press(.right, times: 6)
        XCTAssertTrue(poll(timeout: 5) { cast.exists && cast.frame.minX > app.buttons[A11yID.TV.Detail.favorite].frame.maxX },
                      "Focus is on a person right of the last action")
        press(.up)
        let action = app.buttons.matching(NSPredicate(format: "hasFocus == true AND identifier IN %@", [
            A11yID.TV.Detail.play, A11yID.TV.Detail.restart, A11yID.TV.Detail.watched, A11yID.TV.Detail.favorite
        ])).firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 5), "Up reaches the action row")
    }

    /// A title with no backdrop shows its poster beside the title instead,
    /// and no placeholder glyph mid-screen; one with a backdrop shows neither.
    func test_noBackdrop_showsThePosterBesideTheTitle() {
        let app = launchAtHomeTile(scenario: "noBackdrop")
        openDetailFromFocusedTile(app)
        let art = app.descendants(matching: .any)[A11yID.TV.Detail.headerArt]
        XCTAssertTrue(art.waitForExistence(timeout: 10))
        let title = app.descendants(matching: .any)[A11yID.TV.Detail.title]
        XCTAssertGreaterThan(art.frame.minX, title.frame.maxX, "Opposite the title, on the right")
        XCTAssertLessThanOrEqual(art.frame.maxX, app.frame.maxX)
        let startY = art.frame.minY
        press(.down)
        XCTAssertTrue(poll(timeout: 5) { art.frame.minY < startY }, "It scrolls with the header")
    }

    /// An episode's wide art sits top-right, clear of the text beneath it:
    /// pinned at the foot like a poster, it ran across the synopsis
    /// (Benjamin, 2026-10-07).
    func test_noBackdrop_anEpisodesWideArt_staysAboveTheSynopsis() {
        let app = launchAtHomeTile(scenario: "noBackdrop")
        press(.right)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Main.tile(UITestFixtureIdentity.episodeID(season: 1, episode: 1))]))
        openDetailFromFocusedTile(app)
        let art = app.descendants(matching: .any)[A11yID.TV.Detail.headerArt]
        XCTAssertTrue(art.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(art.frame.width, art.frame.height, "Wide art, not a poster")
        let overview = app.descendants(matching: .any)[A11yID.TV.Detail.overview]
        XCTAssertTrue(overview.waitForExistence(timeout: 10))
        XCTAssertLessThanOrEqual(art.frame.maxY, overview.frame.minY, "Above the synopsis")
        XCTAssertFalse(art.frame.intersects(overview.frame))
    }

    func test_withABackdrop_thereIsNoHeaderArt() {
        let app = launchAtHomeTile()
        openDetailFromFocusedTile(app)
        XCTAssertTrue(app.buttons[A11yID.TV.Detail.watched].waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)[A11yID.TV.Detail.headerArt].exists)
    }
}
