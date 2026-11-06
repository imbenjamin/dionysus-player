import XCTest

/// The iPhone Duo's fold layouts, each checked against the fold in the pose
/// that draws it (`CLAUDE.md`, "iPhone Duo: the fold"). Every journey runs
/// these screens in every pose; these are what say the layout is right, not
/// only reached. Elsewhere each test skips: the fold moves nothing unless the
/// phone is partly folded (book or tabletop).
final class DuoFoldJourneyTests: UITestCase {
    // MARK: - The player (`PlayerFoldLayout`)

    /// Tabletop: the picture above the fold, every control below it.
    func testPlayerControlsSitBelowTheFoldInTabletop() throws {
        launch()
        let fold = try foldBand(in: "tabletop")
        let player = openPlayer()
        assertEventually(
            [player.playPauseButton, player.skipForwardButton, player.skipBackwardButton, player.scrubber],
            all: { $0.frame.minY >= fold.maxY },
            "Every control below the fold \(fold)"
        )
    }

    /// Book: the transport on the trailing page.
    func testPlayerTransportSitsOnTheTrailingPageInBook() throws {
        launch()
        let fold = try foldBand(in: "book")
        let player = openPlayer()
        assertEventually(
            [player.playPauseButton, player.skipForwardButton, player.skipBackwardButton, player.scrubber],
            all: { $0.frame.minX >= fold.maxX },
            "The transport on the trailing page, past the fold \(fold)"
        )
    }

    // MARK: - Detail pages (`DetailBookSpread`)

    /// Book: the poster fills the leading page and the content scrolls on
    /// the trailing one.
    func testDetailSpreadsAcrossTheFoldInBook() throws {
        launch()
        let fold = try foldBand(in: "book")
        HomeScreen(app: app).awaitLoaded()
        HomeScreen(app: app).openItem(UITestFixtureIdentity.primaryMovieID)
        let detail = AssetDetailScreen(app: app)
        detail.awaitLoaded()
        let poster = app.descendants(matching: .any)[A11yID.AssetDetail.bookSpreadPoster]
        poster.awaitExistence("the book spread's poster page")
        assertEventually([poster], all: { $0.frame.maxX <= fold.minX + 1 }, "The poster on the leading page, before the fold \(fold)")
        assertEventually([detail.playButton], all: { $0.frame.minX >= fold.maxX }, "Play on the trailing page, past the fold \(fold)")
    }

    // MARK: - Home's hero (`HeroFoldLayout`)

    /// Tabletop: the hero ends at the fold, and the rows start past it.
    func testHomeHeroEndsAtTheFoldInTabletop() throws {
        launch()
        let fold = try foldBand(in: "tabletop")
        let home = HomeScreen(app: app)
        home.awaitLoaded()
        assertEventually([home.heroCarousel.firstMatch], all: { $0.frame.maxY <= fold.minY + 1 }, "The hero ends before the fold \(fold)")
        let libraries = app.descendants(matching: .any)[A11yID.Home.libraryRail].firstMatch
        libraries.awaitExistence("the library row")
        assertEventually([libraries], all: { $0.frame.minY >= fold.maxY }, "The library row starts past the fold \(fold)")
    }

    // MARK: - Centred states (`.centredClearOfTheFold()`)

    /// Book: Search's empty state on the trailing page.
    func testSearchEmptyStateSitsOnTheTrailingPageInBook() throws {
        launch()
        let fold = try foldBand(in: "book")
        let search = openSearchWithNoResults()
        assertEventually([search.emptyState.firstMatch], all: { $0.frame.minX >= fold.maxX }, "Search's empty state past the fold \(fold)")
    }

    /// Tabletop: Search's empty state in the top half.
    func testSearchEmptyStateSitsAboveTheFoldInTabletop() throws {
        launch()
        let fold = try foldBand(in: "tabletop")
        let search = openSearchWithNoResults()
        assertEventually([search.emptyState.firstMatch], all: { $0.frame.maxY <= fold.minY }, "Search's empty state above the fold \(fold)")
    }

    // MARK: - Helpers

    /// The fold in `pose` (book draws it upright, tabletop across), or a
    /// skip anywhere else.
    private func foldBand(in pose: String) throws -> CGRect {
        guard duoPose == pose, let fold = duoFoldBand() else {
            throw XCTSkip("Only the iPhone Duo in \(pose) pose draws this layout.")
        }
        let upright = fold.height > fold.width
        guard upright == (pose == "book") else {
            throw XCTSkip("The fold doesn't lie the way \(pose) pose holds it: \(fold).")
        }
        return fold
    }

    private func openPlayer() -> PlayerScreen {
        let home = HomeScreen(app: app)
        home.awaitLoaded()
        home.openItem(UITestFixtureIdentity.primaryMovieID)
        AssetDetailScreen(app: app).play()
        let player = PlayerScreen(app: app)
        player.awaitControls()
        return player
    }

    private func openSearchWithNoResults() -> SearchScreen {
        HomeScreen(app: app).awaitLoaded()
        TabBar(app: app).search.tap()
        let search = SearchScreen(app: app)
        search.search(for: "zzzz-no-such-title")
        search.emptyState.firstMatch.awaitExistence("Search's empty state")
        return search
    }

    /// Waits for every element to satisfy `condition`: the fold layouts move
    /// a pass after the screen appears, once the fold is read.
    private func assertEventually(
        _ elements: [XCUIElement],
        all condition: @escaping (XCUIElement) -> Bool,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let met = NSPredicate { _, _ in elements.allSatisfy { $0.exists && condition($0) } }
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: met, object: nil)], timeout: Self.defaultTimeout)
        XCTAssertEqual(
            result, .completed,
            "\(message): \(elements.map { "\($0.identifier) \($0.exists ? "\($0.frame)" : "missing")" })",
            file: file, line: line
        )
    }
}
