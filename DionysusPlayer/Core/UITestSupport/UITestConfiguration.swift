#if DEBUG
import Foundation

/// Which fixture set `UITestStubURLProtocol` serves for this launch.
///
/// Chosen once at launch and never changed mid-run: flipping it while running
/// would race `MainTabView`'s `onChange(of: ConnectivityMonitor.shared.isOffline)`,
/// which silently re-signs-in when connectivity returns.
enum UITestScenario: String {
    /// A small complete catalogue: two libraries, movies, a two-season show, a
    /// box set and a playlist. What almost every test wants.
    case standard

    /// Every list endpoint returns zero items, for empty-state coverage.
    case emptyLibrary

    /// Browse endpoints return 500. Auth still succeeds, so the test reaches
    /// a signed-in error state rather than being stuck on login.
    case serverError

    /// Browse endpoints return 401 once per path, then succeed, exercising
    /// `JellyfinAPIClient.sendRaw`'s silent re-authentication.
    case unauthorized

    /// Every request fails as if the network were unreachable, driving
    /// `ConnectivityMonitor.isOffline` and the `OfflineStateView` branches.
    case offline

    /// `.standard`'s catalogue with `CanDelete: false` on every item and any
    /// `DELETE` refused: a signed-in user not allowed to delete. Covers
    /// `AssetActionsButton`'s permission gate, which drops the affordance rather
    /// than disabling it, and — via a forced request — the
    /// 401-means-not-permitted path in `JellyfinAPIClient.deleteItem`.
    ///
    /// The toolbar item remains: without delete, `AssetActionsButton` collapses
    /// from its `ellipsis` overflow to the lone "Add to Playlist" control, which
    /// is always available. A journey asserting the gate therefore asserts the
    /// absence of `moreButton`/`deleteButton`, not of the toolbar item.
    case noDeletePermission

    /// `.standard`'s catalogue with every playlist's permissions lookup
    /// answering 404 — Jellyfin's "permissions not found" for a user who neither
    /// owns the playlist nor is shared on it — and any add or removal refused
    /// with 403.
    ///
    /// Covers two gates reading the same server answer: `PlaylistItemList`'s
    /// remove affordance, which renders no `.contextMenu` item, and
    /// `AddToPlaylistSheet`'s destination list, which comes back empty so the
    /// picker offers only "New Playlist". Creating one still works, needing no
    /// server permission.
    ///
    /// `.standard` is not a blanket "everything is editable": `readOnlyPlaylist`
    /// answers 404 there too, so the picker's filter has something to reject in
    /// the normal case.
    case noPlaylistEditPermission

    /// `.standard`'s catalogue with a hero item's `Logo` delayed past
    /// `LogoImageView`'s fallback-reveal delay, every other image resolving as
    /// usual. Lets a test observe the timeout-triggered fallback-text reveal
    /// without depending on real network timing.
    case slowLogoImage
}

/// Launch-argument switches the UI test runner uses to put the app into a
/// deterministic state.
///
/// Read through `UserDefaults` rather than by parsing `ProcessInfo.arguments`:
/// `NSArgumentDomain` already turns `-Key value` pairs into defaults, it is
/// volatile so `ServerSessionStore.clearAll()` can't collide with it, and it is
/// the same mechanism the tests use for the app's own `@AppStorage` keys.
///
/// Every flag therefore needs an explicit `YES`/`NO`: a bare `-Flag` would
/// consume the next argument as its value and shift every pair after it.
enum UITestConfiguration {
    private static func flag(_ key: String) -> Bool {
        UserDefaults.standard.bool(forKey: key)
    }

    /// Master switch: nothing else here has effect without it, so a stray
    /// `-UITestScenario` in a normal debug run is inert.
    static var isActive: Bool { flag("UITestMode") }

    static var scenario: UITestScenario {
        guard let raw = UserDefaults.standard.string(forKey: "UITestScenario"),
              let scenario = UITestScenario(rawValue: raw) else { return .standard }
        return scenario
    }

    /// Wipe persisted state before `AppState` reads any of it.
    static var resetsState: Bool { flag("UITestResetState") }

    /// Plant a server configuration and credentials so a test starts at `.main`
    /// rather than replaying setup and login. In-process because the credentials
    /// live in the Keychain, which the runner can't write into this app's access
    /// group from outside.
    static var seedsSession: Bool { flag("UITestSeedSession") }

    static var disablesAnimations: Bool { flag("UITestDisableAnimations") }

    /// `PlayerControlsOverlay` hides 3s after the last interaction except under
    /// VoiceOver, which XCUITest doesn't enable, so every player assertion would
    /// otherwise race that timer.
    static var disablesControlAutoHide: Bool { flag("UITestDisableControlAutoHide") }

    /// The server address a seeded session points at. Arbitrary, since every
    /// request is intercepted, but it must be a real URL and must match what
    /// `UITestStubURLProtocol.respond` claims to have responded from.
    static let stubServerURL = URL(string: UITestFixtureIdentity.serverAddress)!

    static let stubUserID = "uitest-user-0001"
    static let stubUsername = UITestFixtureIdentity.username
    static let stubPassword = UITestFixtureIdentity.password
    static let stubAccessToken = "uitest-access-token"
    static let stubServerName = UITestFixtureIdentity.serverName
}
#endif
