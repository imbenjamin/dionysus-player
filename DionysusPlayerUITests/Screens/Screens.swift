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

    func awaitLoaded(file: StaticString = #filePath, line: UInt = #line) {
        // Waits on a real media card rather than on `root`, which exists
        // during the loading and error branches too — "Home appeared" and
        // "Home has content" are different claims, and a test that means the
        // second should not pass on the first.
        card(UITestFixtureIdentity.primaryMovieID)
            .awaitExistence("Home's rails to populate", file: file, line: line)
    }

    /// One media tile, addressed by the item it shows. Works on Home, in a
    /// grid, and in search results alike — `PosterCard`/`LandscapeMediaCard`
    /// carry the same identifier everywhere they appear.
    ///
    /// `.firstMatch` because that is exactly why: one item legitimately
    /// appears in several places at once (the hero carousel *and* Recently
    /// Added, say), so the identifier is not unique on screen and must not
    /// be treated as though it were. Any of the matches is the same item and
    /// pushes the same destination.
    func card(_ itemID: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: A11yID.Media.card(itemID)).firstMatch
    }

    func openItem(_ itemID: String, file: StaticString = #filePath, line: UInt = #line) {
        let tile = card(itemID)
        tile.awaitExistence("the tile for \(itemID)", file: file, line: line)
        tile.tap()
    }
}

// MARK: - Collection grid

struct CollectionScreen: Screen {
    let app: XCUIApplication

    var sortMenu: XCUIElement { app.buttons[A11yID.Collection.sortMenu] }
    var randomButton: XCUIElement { app.buttons[A11yID.Collection.randomButton] }

    /// A grid tile — the same `A11yID.Media.card(_:)` every other media tile
    /// uses, so this is a `PosterCard` specifically. Worth knowing: Home's
    /// hero carousel carries the identifier too, so a test that means "open
    /// this from a poster grid" has to be *here*, not on Home.
    func card(_ itemID: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: A11yID.Media.card(itemID)).firstMatch
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
    var favoriteButton: XCUIElement { app.buttons[A11yID.AssetDetail.favoriteButton] }
    var watchedButton: XCUIElement { app.buttons[A11yID.AssetDetail.watchedButton] }

    func awaitLoaded(file: StaticString = #filePath, line: UInt = #line) {
        playButton.awaitExistence("the detail page's play button", file: file, line: line)
    }

    func play(file: StaticString = #filePath, line: UInt = #line) {
        awaitLoaded(file: file, line: line)
        playButton.tap()
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
        app.descendants(matching: .any).matching(identifier: A11yID.Media.card(itemID)).firstMatch
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
    var scrubber: XCUIElement { app.descendants(matching: .any)[A11yID.Player.scrubber] }

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
}
