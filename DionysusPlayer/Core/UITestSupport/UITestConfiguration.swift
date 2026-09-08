#if DEBUG
import Foundation

/// Which fixture set `UITestStubURLProtocol` serves for this launch.
///
/// A scenario is chosen once, at launch, and never changes mid-run — flipping
/// it while the app is running would race `MainTabView`'s
/// `onChange(of: ConnectivityMonitor.shared.isOffline)`, which silently
/// re-signs-in when connectivity returns.
enum UITestScenario: String {
    /// A small but complete catalogue: two libraries, movies, a show with
    /// two seasons, a box set, and a playlist. What almost every test wants.
    case standard

    /// Every list endpoint returns zero items, for empty-state coverage.
    case emptyLibrary

    /// Browse endpoints return 500. Auth still succeeds, so the test reaches
    /// a signed-in error state rather than being stuck on login.
    case serverError

    /// Browse endpoints return 401 once per path, then succeed — exercising
    /// `JellyfinAPIClient.sendRaw`'s silent re-authentication.
    case unauthorized

    /// Every request fails as if the network were unreachable, driving
    /// `ConnectivityMonitor.isOffline` and the `OfflineStateView` branches.
    case offline

    /// The same catalogue as `.standard`, but every item comes back with
    /// `CanDelete: false` and any `DELETE` is refused — the signed-in user
    /// who simply isn't allowed to delete anything. Covers the permission
    /// gate on `AssetActionsButton`, which drops its delete affordance
    /// entirely in this state rather than disabling it, and (via a
    /// deliberately forced request) the 401-means-"not permitted" path in
    /// `JellyfinAPIClient.deleteItem`.
    ///
    /// Note this leaves the *button* present, not absent: with delete gone,
    /// `AssetActionsButton` collapses from its `ellipsis` overflow to the
    /// lone "Add to Playlist" control, which is always available (see
    /// `JellyfinAPIClient.createPlaylist`). A journey asserting the gate
    /// therefore asserts the absence of `moreButton`/`deleteButton`, not of
    /// the toolbar item as a whole.
    case noDeletePermission

    /// The same catalogue as `.standard`, but `GET /Playlists/{id}/Users/
    /// {userID}` (`JellyfinAPIClient.playlistUserPermissions`) answers 404
    /// for *every* playlist — Jellyfin's own "permissions not found" for a
    /// user who is neither the playlist's owner nor shared on it — and any
    /// playlist-item add or removal is refused with 403.
    ///
    /// Covers two permission gates that read the same server answer:
    /// `PlaylistItemList`'s remove affordance (`AssetDetailViewModel
    /// .canEditPlaylist`), which renders no `.contextMenu` item at all in
    /// this state; and `AddToPlaylistSheet`'s destination list
    /// (`JellyfinAPIClient.editablePlaylists`), which comes back empty so
    /// the picker offers only "New Playlist". Creating one still works here,
    /// deliberately — that needs no server permission either.
    ///
    /// Note `.standard` is *not* a blanket "everything is editable": the
    /// `readOnlyPlaylist` fixture answers 404 there too, so the picker's
    /// filter has something real to reject in the normal case.
    case noPlaylistEditPermission

    /// The same catalogue as `.standard`, but a hero item's `Logo` image
    /// specifically is delayed past `LogoImageView`'s own fallback-reveal
    /// delay — every other image (posters, backdrops, thumbnails) resolves
    /// immediately as usual. Exists so a UI test can observe the
    /// timeout-triggered fallback-text reveal deterministically, without
    /// depending on real network timing. See `UITestStubURLProtocol
    /// .slowLogoImageDelay`.
    case slowLogoImage
}

/// Launch-argument switches the UI test runner uses to put the app into a
/// deterministic state.
///
/// Read through `UserDefaults` rather than by hand-parsing
/// `ProcessInfo.arguments`: the `NSArgumentDomain` already turns
/// `-Key value` pairs into defaults, it is volatile (nothing here survives
/// the process, so `ServerSessionStore.clearAll()` can't collide with it),
/// and it is the same mechanism the tests use to force the app's own
/// `@AppStorage` keys — one convention instead of two.
///
/// Every flag therefore takes an explicit `YES`/`NO` value. A bare `-Flag`
/// would consume the *next* argument as its value and silently shift every
/// pair after it.
enum UITestConfiguration {
    private static func flag(_ key: String) -> Bool {
        UserDefaults.standard.bool(forKey: key)
    }

    /// Master switch. Nothing else in this file has any effect without it,
    /// so a stray `-UITestScenario` in a normal debug run is inert.
    static var isActive: Bool { flag("UITestMode") }

    static var scenario: UITestScenario {
        guard let raw = UserDefaults.standard.string(forKey: "UITestScenario"),
              let scenario = UITestScenario(rawValue: raw) else { return .standard }
        return scenario
    }

    /// Wipe persisted state before `AppState` reads any of it — see
    /// `UITestHarness.installIfNeeded()` for why the ordering matters.
    static var resetsState: Bool { flag("UITestResetState") }

    /// Plant a server configuration and credentials so a test starts at
    /// `.main` instead of replaying server setup and login. Has to happen
    /// in-process: the server config is plain `UserDefaults`, but the
    /// credentials live in the Keychain, which the test runner cannot write
    /// into this app's access group from outside.
    static var seedsSession: Bool { flag("UITestSeedSession") }

    static var disablesAnimations: Bool { flag("UITestDisableAnimations") }

    /// `PlayerControlsOverlay` hides itself 3s after the last interaction,
    /// except under VoiceOver — which XCUITest does not turn on. Without
    /// this, every player assertion races that timer.
    static var disablesControlAutoHide: Bool { flag("UITestDisableControlAutoHide") }

    /// The server address a seeded session points at. Arbitrary — every
    /// request is intercepted before it reaches the network — but it has to
    /// be a real URL, and it has to match what `UITestStubURLProtocol`
    /// claims to have responded from (see that type's `respond` for why).
    static let stubServerURL = URL(string: UITestFixtureIdentity.serverAddress)!

    static let stubUserID = "uitest-user-0001"
    static let stubUsername = UITestFixtureIdentity.username
    static let stubPassword = UITestFixtureIdentity.password
    static let stubAccessToken = "uitest-access-token"
    static let stubServerName = UITestFixtureIdentity.serverName
}
#endif
