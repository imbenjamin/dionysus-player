import XCTest

/// Screen objects: one per screen, each wrapping `XCUIApplication` and
/// exposing what a *journey* does on that screen rather than which queries
/// find its controls.
///
/// The point is that every selector lives in exactly one place. When a view
/// changes, one screen object changes; the tests, which read as sequences of
/// user intent, do not. Selectors are `A11yID` constants — the same file the
/// app applies, compiled into this target (see `project.yml`) — so a renamed
/// identifier is a compile error here rather than a mysterious timeout.
///
/// Note there are no screen-root selectors: SwiftUI's
/// `.accessibilityIdentifier` on a container is not reliably scoped to that
/// container (see `A11yID`'s own note), so each screen proves it is on
/// screen via a control only it has.
@MainActor
protocol Screen {
    var app: XCUIApplication { get }
}

extension Screen {
    /// The real copy of a media tile carrying `identifier`, when more than
    /// one element in the tree carries it.
    ///
    /// Plain `.firstMatch` isn't safe for this: `HeroRailView`'s carousel
    /// keeps off-screen duplicate copies of its slides for its own paging/
    /// loop bookkeeping — measured live at a full screen-width *outside*
    /// either horizontal edge (`(-820, 0, 820, 523.5)` and
    /// `(5740, 0, 820, 523.5)` on an 820pt-wide iPad) — and those can sort
    /// *before* the actual tile in traversal order. Tapping one of those
    /// synthesizes a touch at whatever real screen point its out-of-bounds
    /// frame happens to imply, landing on a completely different,
    /// currently-visible item instead — silently, no error (confirmed live:
    /// tapping the fixture's primary movie this way opened a different
    /// show's detail page). `.isHittable` doesn't catch this either — it
    /// read `true` for the same off-window element.
    ///
    /// The horizontal position is what actually tells the two apart: a
    /// normal tile, even one below the fold that `tap()` has to scroll to
    /// first, still sits within the screen's own width — only the
    /// carousel's padding pages sit outside it. Filtering on that, rather
    /// than vertical position, is what lets a genuinely off-screen-but-real
    /// tile (auto-scrolled to on tap, same as ever) keep working.
    func onScreenMatch(identifier: String, in app: XCUIApplication) -> XCUIElement {
        let matches = app.descendants(matching: .any).matching(identifier: identifier)
        let screenWidth = app.frame.width
        for index in 0..<matches.count {
            let candidate = matches.element(boundBy: index)
            let frame = candidate.frame
            if frame.minX >= 0, frame.maxX <= screenWidth {
                return candidate
            }
        }
        return matches.firstMatch
    }

    /// `LogoImageView`'s otherwise accessibility-hidden/`.ignore`-collapsed
    /// fallback-text reveal, surfaced only under the UI test harness — see
    /// `A11yID.Media.heroLogoFallbackVisible`'s doc comment. Shared across
    /// screens rather than duplicated per screen object since the same
    /// identifier means the same thing wherever `LogoImageView` renders a
    /// text fallback (`AssetDetailScreen`'s hero header,
    /// `PlayerScreen`'s title row).
    var heroLogoFallbackVisible: XCUIElement {
        app.descendants(matching: .any)[A11yID.Media.heroLogoFallbackVisible]
    }
}

// MARK: - Server setup

struct ServerSetupScreen: Screen {
    let app: XCUIApplication

    var addressField: XCUIElement { app.textFields[A11yID.ServerSetup.addressField] }
    var connectButton: XCUIElement { app.buttons[A11yID.ServerSetup.connectButton] }
    var errorMessage: XCUIElement { app.descendants(matching: .any)[A11yID.ServerSetup.errorMessage] }

    func awaitLoaded(file: StaticString = #filePath, line: UInt = #line) {
        addressField.awaitExistence("the server address field", file: file, line: line)
    }

    func connect(to address: String, file: StaticString = #filePath, line: UInt = #line) {
        awaitLoaded(file: file, line: line)
        addressField.tap()
        addressField.typeText(address)
        connectButton.tap()
    }
}

// MARK: - Login

struct LoginScreen: Screen {
    let app: XCUIApplication

    var usernameField: XCUIElement { app.textFields[A11yID.Login.usernameField] }
    var passwordField: XCUIElement { app.secureTextFields[A11yID.Login.passwordField] }
    var signInButton: XCUIElement { app.buttons[A11yID.Login.signInButton] }
    var changeServerButton: XCUIElement { app.buttons[A11yID.Login.changeServerButton] }
    var errorMessage: XCUIElement { app.descendants(matching: .any)[A11yID.Login.errorMessage] }

    func awaitLoaded(file: StaticString = #filePath, line: UInt = #line) {
        usernameField.awaitExistence("the username field", file: file, line: line)
    }

    func signIn(username: String, password: String, file: StaticString = #filePath, line: UInt = #line) {
        awaitLoaded(file: file, line: line)
        usernameField.tap()
        usernameField.typeText(username)
        passwordField.tap()
        passwordField.typeText(password)
        signInButton.tap()
    }
}

// MARK: - Tab bar

/// Resolving a tab differs by device, and neither approach works on both.
///
/// On iPad the tab bar is SwiftUI's own floating pill, and the identifier set
/// inside `.tabItem` reaches the button — but it resolves to two nested
/// buttons with identical frames, hence `.firstMatch`.
///
/// On iPhone the same `.tabItem` is converted into a UIKit `UITabBarItem`,
/// which carries no accessibility identifier at all: the buttons under
/// `TabBar` have labels and nothing else. Verified against the live tree on
/// both, after an iPhone run failed on every tab interaction while iPad
/// passed.
///
/// The fallback is positional rather than by label. Labels would work — the
/// tab titles are stable — but they are `String(localized:)` values, so a
/// label-based selector silently breaks the day the string catalogue gains a
/// second language. Tab *order* is fixed in `MainTabView` and is not
/// localized.
struct TabBar: Screen {
    let app: XCUIApplication

    var home: XCUIElement { tab(A11yID.Tabs.home, index: 0) }
    var search: XCUIElement { tab(A11yID.Tabs.search, index: 1) }
    var downloads: XCUIElement { tab(A11yID.Tabs.downloads, index: 2) }
    var profile: XCUIElement { tab(A11yID.Tabs.profile, index: 3) }

    private func tab(_ identifier: String, index: Int) -> XCUIElement {
        let identified = app.buttons.matching(identifier: identifier).firstMatch
        guard identified.exists else {
            return app.tabBars.buttons.element(boundBy: index)
        }
        return identified
    }
}

// MARK: - Home

struct HomeScreen: Screen {
    let app: XCUIApplication

    var heroCarousel: XCUIElement { app.descendants(matching: .any)[A11yID.Home.heroCarousel] }

    /// The "Recently Added Movies" rail's "See All" link, pushing the
    /// Movies library's collection grid. The identifier key mirrors
    /// `CollectionQuery.identifierKey`'s format
    /// (`\(parentID ?? "all").\(includeItemTypes)`) rather than being built
    /// from a real `CollectionQuery` — that extension lives in the app
    /// module, which this target doesn't link (see its own doc comment) —
    /// so this has to be kept in sync by hand if `HomeViewModel`'s rail
    /// construction changes what this rail's `seeAllQuery` looks like.
    ///
    /// `.firstMatch`, not a bare subscript: `identifierKey` only encodes
    /// `parentID`/`includeItemTypes`, not any further filter, so a
    /// genre-based dynamic rail scoped to the same library and type (a
    /// "Drama Movies" rail, say) collides with this one on identifier —
    /// measured live. Curated rails render before dynamic ones
    /// (`HomeViewModel.fetchCuratedRails`/`loadMoreDynamicRails`), so the
    /// first match is reliably this rail, not the dynamic one.
    var seeAllRecentMoviesButton: XCUIElement {
        app.buttons.matching(identifier: A11yID.Home.seeAll("\(UITestFixtureIdentity.moviesLibraryID).Movie")).firstMatch
    }

    /// `timeout` defaults to the suite-wide `UITestCase.defaultTimeout`, but
    /// takes an explicit override for `.unauthorized`'s silent-reauth path —
    /// `reauthBackoffSchedule` adds real, if invisible, latency the default
    /// budget doesn't account for.
    func awaitLoaded(timeout: TimeInterval = UITestCase.defaultTimeout, file: StaticString = #filePath, line: UInt = #line) {
        // Waits on a real media card rather than on `root`, which exists
        // during the loading and error branches too — "Home appeared" and
        // "Home has content" are different claims, and a test that means the
        // second should not pass on the first.
        card(UITestFixtureIdentity.primaryMovieID)
            .awaitExistence("Home's rails to populate", timeout: timeout, file: file, line: line)
    }

    /// One media tile, addressed by the item it shows. Works on Home, in a
    /// grid, and in search results alike — `PosterCard`/`LandscapeMediaCard`
    /// carry the same identifier everywhere they appear.
    ///
    /// Not plain `.firstMatch`: one item legitimately appears in several
    /// places at once (the hero carousel *and* Recently Added, say), so the
    /// identifier is not unique on screen — and on Home specifically, one of
    /// those duplicates can be the hero carousel's own off-screen paging
    /// buffer. See `onScreenMatch(identifier:in:)`'s doc comment for why
    /// that specific duplicate is unsafe to tap.
    func card(_ itemID: String) -> XCUIElement {
        onScreenMatch(identifier: A11yID.Media.card(itemID), in: app)
    }

    func openItem(_ itemID: String, file: StaticString = #filePath, line: UInt = #line) {
        let tile = card(itemID)
        tile.awaitExistence("the tile for \(itemID)", file: file, line: line)
        tile.tap()
    }

    /// Opens a library card that may sit past the initial viewport on a
    /// narrower device. `LibraryRailView`'s four cards (Movies, TV Shows,
    /// Collections, Playlists) all fit on an iPad without scrolling, but
    /// the later ones run off the right edge on iPhone — measured live,
    /// tapping one there fails with "Activation point invalid" rather than
    /// XCUITest transparently auto-scrolling the way it does for a normal
    /// (non-lazy) off-screen element. A single, bounded swipe on the rail
    /// itself first — unlike the open-ended scroll gestures this suite
    /// otherwise avoids — reliably brings the later cards into view; a
    /// no-op on a device where they were already visible.
    func openLibrary(_ libraryID: String, file: StaticString = #filePath, line: UInt = #line) {
        let rail = app.descendants(matching: .any)[A11yID.Home.libraryRail]
        if rail.exists {
            rail.swipeLeft()
        }
        openItem(libraryID, file: file, line: line)
    }
}

// MARK: - Collection grid

struct CollectionScreen: Screen {
    let app: XCUIApplication

    var sortMenu: XCUIElement { app.buttons[A11yID.Collection.sortMenu] }
    var randomButton: XCUIElement { app.buttons[A11yID.Collection.randomButton] }
    var resetFiltersButton: XCUIElement { app.buttons[A11yID.Collection.resetFiltersButton] }
    var noFilterMatches: XCUIElement { app.descendants(matching: .any)[A11yID.Collection.noFilterMatches] }

    /// One of the five filter pills — `facet` is a `CollectionFilterFacet`
    /// raw value ("genre", "studio", "decade", "watched", "favorites"), not
    /// a label. Opens the pill's `Menu`.
    func filterPill(_ facet: String) -> XCUIElement {
        app.buttons[A11yID.Collection.filterPill(facet)]
    }

    /// Picks one option out of an already-open filter `Menu` — the options
    /// render as plain `Button`s labelled with the option's own display text
    /// (fixture data — a genre/studio name, a decade, "Favorites" — not app
    /// UI copy, so matching on it isn't the localized-label trap the rest of
    /// this suite avoids). Verified live: a `Picker` alone inside a `Menu`
    /// flattens straight to top-level option buttons, no submenu.
    ///
    /// Scoped to `app.cells` rather than a bare `app.buttons[label]`: the
    /// Favorites facet's own *unselected* pill title is also "Favorites"
    /// (`FilterMenu`'s `title`, shown until something's picked), and that
    /// pill button stays in the tree behind the open menu — a plain label
    /// lookup for "Favorites" is ambiguous the moment that pill is on
    /// screen. Verified live: only the menu's own options render inside a
    /// `Cell` (`CollectionView` rows); the pill trigger doesn't.
    func selectFilterOption(_ label: String) {
        app.cells.buttons[label].tap()
    }

    /// A grid tile — the same `A11yID.Media.card(_:)` every other media tile
    /// uses, so this is a `PosterCard` specifically. Worth knowing: Home's
    /// hero carousel carries the identifier too, so a test that means "open
    /// this from a poster grid" has to be *here*, not on Home.
    func card(_ itemID: String) -> XCUIElement {
        onScreenMatch(identifier: A11yID.Media.card(itemID), in: app)
    }

    func awaitLoaded(_ itemID: String, file: StaticString = #filePath, line: UInt = #line) {
        card(itemID).awaitExistence("the grid tile for \(itemID)", file: file, line: line)
    }
}

// MARK: - Asset detail

struct AssetDetailScreen: Screen {
    let app: XCUIApplication

    /// One identifier covers Play and Resume — the label changes with watch
    /// state, the action does not.
    var playButton: XCUIElement { app.buttons[A11yID.AssetDetail.playButton] }
    /// Only present for a part-watched item, alongside Resume.
    var restartButton: XCUIElement { app.buttons[A11yID.AssetDetail.restartButton] }
    var favoriteButton: XCUIElement { app.buttons[A11yID.AssetDetail.favoriteButton] }
    var watchedButton: XCUIElement { app.buttons[A11yID.AssetDetail.watchedButton] }

    /// Present only when the server says this user may delete this item, so
    /// asserting its *absence* is asserting the permission gate — see
    /// `A11yID.AssetDetail.deleteButton`.
    var deleteButton: XCUIElement { app.buttons[A11yID.AssetDetail.deleteButton] }

    /// The confirmation dialog's own destructive action. Scoped to
    /// `app.sheets` because a bare `app.buttons[...]` subscript matches
    /// labels as well as identifiers, so an unscoped lookup can collide with
    /// the control that raised the dialog.
    var deleteConfirmButton: XCUIElement {
        app.sheets.buttons.matching(identifier: A11yID.AssetDetail.deleteConfirmButton).firstMatch
    }

    /// The dialog's "…and Device" action — only offered when a local
    /// download of the target exists.
    var deleteWithDownloadButton: XCUIElement {
        app.sheets.buttons.matching(identifier: A11yID.AssetDetail.deleteWithDownloadButton).firstMatch
    }

    /// Confirms a deletion that's already been started by tapping
    /// `deleteButton` (or picking a row from its menu).
    func confirmDelete(file: StaticString = #filePath, line: UInt = #line) {
        deleteConfirmButton.awaitExistence("the delete confirmation", file: file, line: line)
        deleteConfirmButton.tap()
    }

    /// A show's episode row — its title/overview half, which switches this
    /// page's own content to that episode in place rather than pushing a
    /// new screen. See `A11yID.AssetDetail.episodeRow(_:)`'s doc comment.
    func episodeRow(_ episodeID: String) -> XCUIElement {
        app.buttons[A11yID.AssetDetail.episodeRow(episodeID)]
    }

    func awaitLoaded(file: StaticString = #filePath, line: UInt = #line) {
        playButton.awaitExistence("the detail page's play button", file: file, line: line)
    }

    func play(file: StaticString = #filePath, line: UInt = #line) {
        awaitLoaded(file: file, line: line)
        playButton.tap()
    }

    /// One playlist member row — see `A11yID.Playlist.row(_:)`'s doc
    /// comment for why this needs its own identifier rather than being
    /// found by label.
    func playlistRow(_ playlistItemID: String) -> XCUIElement {
        app.buttons[A11yID.Playlist.row(playlistItemID)]
    }

    /// The row's `.contextMenu` "Remove from Playlist" action — the only
    /// removal path (see `PlaylistItemList.onRemove`'s doc comment), so
    /// this needs a long-press to reveal it, same as on a real device.
    func playlistRemoveMenuItem(_ playlistItemID: String) -> XCUIElement {
        app.buttons[A11yID.Playlist.removeMenuItem(playlistItemID)]
    }

    /// Long-presses `playlistItemID`'s row to reveal its context menu, then
    /// taps "Remove from Playlist" — the only removal path this feature
    /// has (see `PlaylistItemList.onRemove`'s doc comment for why).
    func removePlaylistItem(_ playlistItemID: String, file: StaticString = #filePath, line: UInt = #line) {
        let row = playlistRow(playlistItemID)
        row.awaitExistence("playlist row \(playlistItemID)", file: file, line: line)
        row.press(forDuration: 1.0)
        let removeItem = playlistRemoveMenuItem(playlistItemID)
        removeItem.awaitExistence("the Remove from Playlist context menu item", file: file, line: line)
        removeItem.tap()
    }
}

// MARK: - Search

struct SearchScreen: Screen {
    let app: XCUIApplication

    var searchField: XCUIElement { app.searchFields.firstMatch }
    var emptyState: XCUIElement { app.descendants(matching: .any)[A11yID.Search.emptyState] }

    /// A result, addressed by the item it shows — search results carry the
    /// same `A11yID.Media.card(_:)` identifier as every other media tile.
    func result(_ itemID: String) -> XCUIElement {
        onScreenMatch(identifier: A11yID.Media.card(itemID), in: app)
    }

    func awaitLoaded(file: StaticString = #filePath, line: UInt = #line) {
        searchField.awaitExistence("the search field", file: file, line: line)
    }

    func search(for term: String, file: StaticString = #filePath, line: UInt = #line) {
        awaitLoaded(file: file, line: line)
        searchField.tap()
        searchField.typeText(term)
    }
}

// MARK: - Player

struct PlayerScreen: Screen {
    let app: XCUIApplication

    /// There is no screen-root identifier for the player — see
    /// `A11yID.Player`'s note on why one cannot be applied here. The close
    /// button stands in: it exists only while the player is up, which is the
    /// same claim a root identifier would have made.
    var closeButton: XCUIElement { app.buttons[A11yID.Player.closeButton] }
    var playPauseButton: XCUIElement { app.buttons[A11yID.Player.playPauseButton] }
    var skipForwardButton: XCUIElement { app.buttons[A11yID.Player.skipForwardButton] }
    var skipBackwardButton: XCUIElement { app.buttons[A11yID.Player.skipBackwardButton] }
    var scrubber: XCUIElement { app.descendants(matching: .any)[A11yID.Player.scrubber] }
    var elapsedLabel: XCUIElement { app.descendants(matching: .any)[A11yID.Player.elapsedLabel] }
    var tracksButton: XCUIElement { app.buttons[A11yID.Player.tracksButton] }
    var chaptersButton: XCUIElement { app.buttons[A11yID.Player.chaptersButton] }
    var chapterPicker: XCUIElement { app.descendants(matching: .any)[A11yID.Player.chapterPicker] }

    /// The close button appearing means the controls overlay is up and
    /// drivable, not merely that the cover presented. Launched with
    /// `-UITestDisableControlAutoHide`, so it will not fade back out.
    func awaitControls(file: StaticString = #filePath, line: UInt = #line) {
        closeButton.awaitExistence("the player's controls", file: file, line: line)
    }

    func close(file: StaticString = #filePath, line: UInt = #line) {
        awaitControls(file: file, line: line)
        closeButton.tap()
    }

    /// One of the track picker's two root-page rows — "audio" or
    /// "subtitle" — which drills into that kind's leaf page.
    ///
    /// `.descendants(matching: .any)`, not `.buttons` — measured live,
    /// `navigationRow`'s `.accessibilityElement(children: .ignore)` reports
    /// as an `Other`, not a `Button`, with the real `Button` nested one
    /// level underneath carrying no identifier of its own (unlike
    /// `ChapterPickerOverlay`'s row, which explicitly adds `.isButton` via
    /// `.accessibilityAddTraits` and so reports as `Button` correctly).
    /// `.tap()` works on the found element regardless of its reported type.
    func trackNavigationRow(_ kind: String) -> XCUIElement {
        app.descendants(matching: .any)[A11yID.Player.trackNavigationRow(kind)]
    }

    /// A leaf page's own selectable row, addressed by `PlaybackTrack.id` —
    /// see `A11yID.Player.trackOption(_:_:)`'s doc comment for the id
    /// scheme, and `trackNavigationRow(_:)`'s own doc comment just above
    /// for why this is `.descendants(matching: .any)` rather than
    /// `.buttons` — `selectionRow` has the identical `Other`-not-`Button`
    /// quirk. Both leaves use `PreviewPlaybackEngine`'s fixed, canned
    /// tracks (ids 0 and 1), not anything derived from
    /// `UITestFixtureLibrary`'s own `MediaSourceInfo` — the player never
    /// touches that; only `DownloadButton`'s own `playbackInfo` fetch does.
    func trackOption(_ kind: String, _ id: Int) -> XCUIElement {
        app.descendants(matching: .any)[A11yID.Player.trackOption(kind, id)]
    }

    var subtitleOffOption: XCUIElement { app.descendants(matching: .any)[A11yID.Player.subtitleOffOption] }

    /// A chapter picker row, addressed by `Chapter.index` (0-based).
    func chapterOption(_ index: Int) -> XCUIElement {
        app.buttons[A11yID.Player.chapterOption(index)]
    }
}

// MARK: - Asset detail (download)

extension AssetDetailScreen {
    /// `DownloadButton`'s one identifier, shared across every state
    /// (idle/resolving/downloading/downloaded) — see its own doc comment.
    var downloadButton: XCUIElement { app.buttons[A11yID.AssetDetail.downloadButton] }

    /// Waits for the download button to reach its "Downloaded" state.
    ///
    /// Asserts on the *label* rather than existence, because the identifier
    /// is deliberately the same in every state — which also means a failure
    /// here can't distinguish "still downloading" from "failed and fell
    /// back to the idle icon", so the message names both. (Measured live:
    /// a download whose bytes fail `DownloadManager`'s duration validation
    /// lands in `.failed`, whose button label is the plain "Download" it
    /// started as — indistinguishable from never having been tapped.)
    func awaitDownloadCompletion(
        timeout: TimeInterval = UITestCase.defaultTimeout,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let downloaded = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS[c] %@", "Downloaded"),
            object: downloadButton
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [downloaded], timeout: timeout), .completed,
            "The download button never reached its Downloaded state — the download is either still in flight or failed.",
            file: file, line: line
        )
    }
}

// MARK: - Downloads

struct DownloadsScreen: Screen {
    let app: XCUIApplication

    var emptyState: XCUIElement { app.descendants(matching: .any)[A11yID.Downloads.emptyState] }
    var list: XCUIElement { app.descendants(matching: .any)[A11yID.Downloads.list] }
    var selectButton: XCUIElement { app.buttons[A11yID.Downloads.selectButton] }
    var selectAllButton: XCUIElement { app.buttons[A11yID.Downloads.selectAllButton] }
    var deleteSelectedButton: XCUIElement { app.buttons[A11yID.Downloads.deleteSelectedButton] }

    /// Selects every row and deletes them, confirming the dialog.
    ///
    /// `app.buttons["Delete"]` for the confirmation dialog's own destructive
    /// button, not an `A11yID` constant — it carries no explicit identifier
    /// of its own, and nothing else on screen at that moment is labeled
    /// bare "Delete": `deleteSelectedButton`'s own accessibility *label* is
    /// "Delete Selected Downloads" (an icon-only button, see
    /// `DownloadsView.toolbarContent`), and the per-row swipe action that
    /// also says "Delete" only exists outside selection mode, which this
    /// method never leaves.
    func deleteAllRows(file: StaticString = #filePath, line: UInt = #line) {
        selectButton.awaitExistence("the Downloads selection-mode button", file: file, line: line)
        selectButton.tap()
        selectAllButton.awaitExistence("the Select All button", file: file, line: line)
        selectAllButton.tap()
        deleteSelectedButton.tap()
        let confirm = app.buttons["Delete"]
        confirm.awaitExistence("the delete confirmation dialog's Delete button", file: file, line: line)
        confirm.tap()
    }
}

// MARK: - Profile

/// Covers only what's reachable through the account card — sign out and
/// change server. Every other Profile row (`advancedPlaybackLink`,
/// `licenseLink`, ...) sits behind a device-specific fork this screen object
/// deliberately doesn't absorb yet: iPhone reaches them by scrolling one
/// continuous list, iPad by first selecting a sidebar pane
/// (`ProfileSettingsPane`) that carries no identifier of its own. The
/// account card is the one row that's a sidebar destination in its own
/// right on both layouts (see `ProfileView.sidebar`), so it needs no such
/// fork.
struct ProfileScreen: Screen {
    let app: XCUIApplication

    /// A `Button` on iPhone (`ProfileView.accountCard`), a selectable
    /// `List` row on iPad (`ProfileView.sidebar`) — both carry the same
    /// identifier, so this doesn't need to know which rendered.
    var accountCard: XCUIElement { app.descendants(matching: .any)[A11yID.Profile.accountCard] }

    func awaitLoaded(file: StaticString = #filePath, line: UInt = #line) {
        accountCard.awaitExistence("the Profile account card", file: file, line: line)
    }

    /// Opens `AccountDetailsContent` — a sheet on iPhone, a detail pane on
    /// iPad — where sign-out/change-server live.
    func openAccountDetails(file: StaticString = #filePath, line: UInt = #line) {
        awaitLoaded(file: file, line: line)
        accountCard.tap()
    }

    /// Taps Sign Out, then the confirmation dialog's own Sign Out button.
    ///
    /// `app.sheets.buttons["Sign Out"]`, not an `A11yID` constant, for the
    /// dialog's button. A bare `app.buttons["Sign Out"]` is ambiguous —
    /// measured live, XCUITest's bracket subscript matches an element
    /// whose *label* equals the string just as readily as one whose
    /// `identifier` does, so it still finds both the confirmation dialog's
    /// own button *and* the row that triggered it (which keeps its label
    /// "Sign Out" even once `A11yID.Profile.signOutButton` is its
    /// `identifier`). `.sheets` scopes to the dialog's own container,
    /// which the triggering row sits outside of.
    func signOut(file: StaticString = #filePath, line: UInt = #line) {
        openAccountDetails(file: file, line: line)
        let trigger = app.buttons[A11yID.Profile.signOutButton]
        trigger.awaitExistence("the Sign Out row", file: file, line: line)
        trigger.tap()
        let confirm = app.sheets.buttons["Sign Out"]
        confirm.awaitExistence("the sign-out confirmation dialog", file: file, line: line)
        confirm.tap()
    }

    /// Taps Change Server, then the confirmation dialog's own Change Server
    /// button. See `signOut()`'s doc comment for why the dialog button is
    /// scoped to `.sheets` rather than queried as a bare `app.buttons[...]`.
    func changeServer(file: StaticString = #filePath, line: UInt = #line) {
        openAccountDetails(file: file, line: line)
        let trigger = app.buttons[A11yID.Profile.changeServerButton]
        trigger.awaitExistence("the Change Server row", file: file, line: line)
        trigger.tap()
        let confirm = app.sheets.buttons["Change Server"]
        confirm.awaitExistence("the change-server confirmation dialog", file: file, line: line)
        confirm.tap()
    }
}
