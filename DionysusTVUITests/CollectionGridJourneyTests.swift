import XCTest

final class CollectionGridJourneyTests: TVUITestCase {
    func test_grid_showsItsCount_pills_andSixColumns() {
        let app = launchAtHome()
        _ = openMovies(app)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Library.count].exists)
        XCTAssertTrue(app.buttons[A11yID.TV.Library.sort].exists)
        XCTAssertTrue(app.buttons[A11yID.TV.Library.filter("genre")].exists)
        let tiles = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "tv.library.tile."))
        let firstRowY = tiles.element(boundBy: 0).frame.minY
        let inFirstRow = (0..<tiles.count).filter { abs(tiles.element(boundBy: $0).frame.minY - firstRowY) < 30 }.count
        XCTAssertEqual(inFirstRow, 6, "Six posters to a row")
    }

    func test_tile_opensItsDetailPage_andMenuReturnsToIt() {
        let app = launchAtHome()
        _ = openMovies(app)
        press(.right)
        let focused = app.buttons.matching(NSPredicate(format: "hasFocus == true AND identifier BEGINSWITH %@", "tv.library.tile.")).firstMatch
        XCTAssertTrue(focused.waitForExistence(timeout: 5))
        let tile = app.buttons[focused.identifier]
        openDetailFromFocusedTile(app)
        press(.menu)
        XCTAssertTrue(waitForFocus(tile))
    }

    /// Sort sits at the row's right; choosing a field reorders the grid
    /// and leaves focus on the pill.
    func test_sort_reordersTheGrid() {
        let app = launchAtHome()
        _ = openMovies(app)
        let firstByTitle = firstLibraryTile(app).identifier
        // Up lands on the filters, at the left; Sort is at the row's right.
        press(.up)
        let sort = app.buttons[A11yID.TV.Library.sort]
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Library.filter("genre")]))
        XCTAssertGreaterThan(sort.frame.minX, app.buttons[A11yID.TV.Library.filter("favorites")].frame.maxX, "Sort sits right of the filters")
        press(.right, times: 5)
        XCTAssertTrue(waitForFocus(sort))
        press(.select)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Library.option("sort", "field0")]))
        // The menu's second row: Date Added.
        press(.down)
        press(.select)
        XCTAssertTrue(poll(timeout: 1) { sort.hasFocus }, "Focus is back on the pill straight away")
        XCTAssertTrue(poll(timeout: 10) { self.firstLibraryTile(app).exists && self.firstLibraryTile(app).identifier != firstByTitle }, "The grid is in a new order")
    }

    /// Filtering to nothing can't happen through the pills (they cascade),
    /// but a filtered grid must narrow, and Reset must widen it again.
    func test_genreFilter_narrowsTheGrid_andResetWidensIt() {
        let app = launchAtHome()
        _ = openMovies(app)
        let tiles = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "tv.library.tile."))
        let all = tiles.count
        let genre = app.buttons[A11yID.TV.Library.filter("genre")]
        let reset = app.buttons[A11yID.TV.Library.resetFilters]
        XCTAssertFalse(reset.exists, "No Reset with no filter set")
        press(.up)
        XCTAssertTrue(waitForFocus(genre))
        press(.select)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Library.option("genre", "all")]), "The list opens on the current choice")
        press(.down)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Library.option("genre", "0")]))
        press(.select)
        // The pill has focus again at once: tvOS's own menu took over a
        // second to give it back.
        // Polled: `waitForFocus` checks once a second.
        XCTAssertTrue(poll(timeout: 1) { genre.hasFocus }, "Focus is back on the pill straight away")
        XCTAssertFalse(app.buttons[A11yID.TV.Library.option("genre", "all")].exists, "The list closed")
        XCTAssertTrue(poll(timeout: 5) { tiles.count > 0 && tiles.count < all })

        // Reset appears once a filter is set, and one press clears it.
        XCTAssertTrue(reset.waitForExistence(timeout: 5))
        for _ in 0..<6 where !reset.hasFocus { press(.right) }
        XCTAssertTrue(waitForFocus(reset))
        press(.select)
        XCTAssertTrue(poll(timeout: 5) { tiles.count == all }, "Reset shows everything again")
        XCTAssertTrue(poll(timeout: 5) { !reset.exists }, "…and goes away")
        XCTAssertTrue(waitForFocus(genre), "Focus moves to the first pill when Reset removes itself")
    }

    /// Menu closes an open list without choosing, back on its pill; it
    /// doesn't open the rail.
    func test_menu_closesAnOpenList() {
        let app = launchAtHome()
        let movies = openMovies(app)
        let genre = app.buttons[A11yID.TV.Library.filter("genre")]
        press(.up)
        XCTAssertTrue(waitForFocus(genre))
        press(.select)
        let all = app.buttons[A11yID.TV.Library.option("genre", "all")]
        XCTAssertTrue(waitForFocus(all))
        press(.menu)
        XCTAssertTrue(poll(timeout: 1) { genre.hasFocus })
        XCTAssertFalse(all.exists)
        XCTAssertTrue(isCollapsed(movies), "Menu closed the list; it didn't open the rail")
    }

    /// Review Focus 1.
    func test_watchedOnDetail_showsOnTheGridTileAfterBack() {
        let app = launchAtHome()
        _ = openMovies(app)
        let tile = firstLibraryTile(app)
        let tileID = tile.identifier
        let startY = tile.frame.minY
        press(.down, times: 2)
        let lower = app.buttons.matching(NSPredicate(format: "hasFocus == true AND identifier BEGINSWITH %@", "tv.library.tile.")).firstMatch
        XCTAssertTrue(lower.waitForExistence(timeout: 5))
        let lowerID = lower.identifier
        // The tile's value, not its label: labels are localized.
        let valueBefore = app.buttons[lowerID].value as? String
        let top = app.buttons[tileID]
        XCTAssertTrue(poll(timeout: 5) { !top.exists || top.frame.minY < startY - 20 }, "The grid has scrolled")
        let scrolledY = top.exists ? top.frame.minY : nil
        openDetailFromFocusedTile(app)
        let watched = app.buttons[A11yID.TV.Detail.watched]
        let before = watched.label
        for _ in 0..<3 where !watched.hasFocus { press(.right) }
        press(.select)
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", before), object: watched)], timeout: 5), .completed)
        press(.menu)
        let back = app.buttons[lowerID]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        XCTAssertTrue(poll(timeout: 10) { (back.value as? String) != valueBefore }, "The tile beneath shows the new watched state")
        XCTAssertTrue(poll(timeout: 5) { scrolledY.map { top.exists && abs(top.frame.minY - $0) < 4 } ?? !top.exists }, "The grid stayed where it was")
    }

    /// Filtered by Watched, a title marked the other way on its page drops
    /// out of the grid when Menu returns to it (M3 review). Focus goes to
    /// the tile that took its place, here the new last one, rather than to
    /// the vanished one's stale position or the grid's top.
    func test_aTitleLeavingAFilteredGrid_handsFocusToItsNeighbour() {
        let app = launchAtHome()
        _ = openMovies(app)
        let tiles = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "tv.library.tile."))
        let all = tiles.count
        let genre = app.buttons[A11yID.TV.Library.filter("genre")]
        let watchedPill = app.buttons[A11yID.TV.Library.filter("watched")]
        press(.up)
        XCTAssertTrue(waitForFocus(genre))
        for _ in 0..<4 where !watchedPill.hasFocus { press(.right) }
        XCTAssertTrue(waitForFocus(watchedPill))
        press(.select)
        let option = app.buttons[A11yID.TV.Library.option("watched", "0")]
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        press(.down)
        XCTAssertTrue(waitForFocus(option))
        press(.select)
        XCTAssertTrue(poll(timeout: 5) { tiles.count > 1 && tiles.count < all }, "The filter narrowed the grid")
        let count = tiles.count
        XCTAssertLessThanOrEqual(count, 6, "One row, so Right reaches the last title")
        // Focus is held on the pill for a moment while the grid reloads.
        Thread.sleep(forTimeInterval: 1)
        press(.down)
        let anyTile = app.buttons.matching(NSPredicate(format: "hasFocus == true AND identifier BEGINSWITH %@", "tv.library.tile.")).firstMatch
        XCTAssertTrue(anyTile.waitForExistence(timeout: 5), "Down enters the grid")
        // In reading order: the query's own order isn't the grid's.
        let ordered = (0..<count).map { tiles.element(boundBy: $0) }
            .map { ($0.identifier, $0.frame) }
            .sorted { ($0.1.minY, $0.1.minX) < ($1.1.minY, $1.1.minX) }
            .map(\.0)
        let last = app.buttons[ordered[count - 1]]
        let neighbour = app.buttons[ordered[count - 2]]
        for _ in 0..<6 where !last.hasFocus { press(.right) }
        XCTAssertTrue(waitForFocus(last), "Reached the last of \(ordered)")
        openDetailFromFocusedTile(app)
        let watched = app.buttons[A11yID.TV.Detail.watched]
        let before = watched.label
        for _ in 0..<3 where !watched.hasFocus { press(.right) }
        press(.select)
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", before), object: watched)], timeout: 5), .completed)
        press(.menu)
        XCTAssertTrue(poll(timeout: 10) { !last.exists }, "The title left the filtered grid")
        XCTAssertTrue(waitForFocus(neighbour), "Focus is on the tile beside where it was")
    }

    func test_failedLibrary_showsRetry() {
        let app = launchAtHome(scenario: "failingLibrary")
        openRailFromHome(app)
        pressDown(until: app.buttons[A11yID.TV.Sidebar.library(UITestFixtureIdentity.moviesLibraryID)])
        press(.select)
        let retry = app.buttons[A11yID.TV.Library.retry]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFocus(retry))
    }
}
