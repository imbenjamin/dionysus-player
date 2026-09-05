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
