#if DEBUG
import Foundation
import SwiftUI
import UIKit

/// Puts the app into the deterministic state a UI test expects, before any
/// of it has been read.
///
/// Ordering is the whole point of this type. `DionysusPlayerApp` builds its
/// `AppState` eagerly, and `AppState.init` builds a `ServerSessionStore`,
/// which reads `UserDefaults` and the Keychain in its own initializer. Reset
/// and seeding therefore have to happen in `DionysusPlayerApp.init()` —
/// before `AppState()` is constructed, not in a `.task` or `.onAppear`,
/// which run long after the store has already loaded whatever the previous
/// test run left behind.
@MainActor
enum UITestHarness {
    /// Call once, first thing in `DionysusPlayerApp.init()`.
    static func installIfNeeded() {
        guard UITestConfiguration.isActive else { return }

        URLProtocol.registerClass(UITestStubURLProtocol.self)

        if UITestConfiguration.resetsState {
            resetPersistentState()
        }

        if UITestConfiguration.seedsSession {
            seedSession()
        }

        if UITestConfiguration.disablesAnimations {
            UIView.setAnimationsEnabled(false)
        }
    }

    /// Inserts the stub into a session configuration the app builds itself.
    ///
    /// `URLProtocol.registerClass` only reaches `URLSession.shared`, which
    /// covers `JellyfinAPIClient` but not `RemoteImageLoader` or
    /// `DownloadManager` — both configure their own sessions. Those call
    /// this instead. A no-op outside a UI test run, so the call sites stay
    /// unconditional and there is nothing to forget.
    /// `nonisolated`: called from `RemoteImageLoader`'s actor init and from
    /// `DownloadManager`'s static configuration builder, neither of which is
    /// on the main actor. Touches only the configuration passed in.
    nonisolated static func decorate(_ configuration: URLSessionConfiguration) {
        guard UITestConfiguration.isActive else { return }
        configuration.protocolClasses = [UITestStubURLProtocol.self] + (configuration.protocolClasses ?? [])
    }

    /// True when the player should keep its controls on screen. Read by
    /// `PlayerView`'s auto-hide timer, which otherwise races every
    /// assertion: the overlay hides itself 3s after the last interaction
    /// unless VoiceOver is running, and XCUITest does not turn VoiceOver on.
    nonisolated static var keepsPlayerControlsVisible: Bool {
        UITestConfiguration.isActive && UITestConfiguration.disablesControlAutoHide
    }

    // MARK: - State

    /// Clears everything that survives an app *reinstall-less* relaunch, so
    /// one test cannot see another's leftovers. The Keychain matters most
    /// here: it outlives the app container, so without this a signed-in run
    /// would silently seed every later "first launch" test.
    private static func resetPersistentState() {
        ServerSessionStore().clearAll()

        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }

        // Downloaded media lives outside `UserDefaults` — SwiftData rows in
        // Application Support, plus the files themselves.
        removeDownloadArtifacts()
    }

    private static func removeDownloadArtifacts() {
        let manager = FileManager.default
        guard let support = try? manager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) else { return }
        guard let contents = try? manager.contentsOfDirectory(
            at: support, includingPropertiesForKeys: nil
        ) else { return }
        for url in contents {
            try? manager.removeItem(at: url)
        }
    }

    /// Plants a server and a signed-in session so a test can start at
    /// `AppState.Phase.main`.
    ///
    /// Has to run in-process: the server configuration is plain
    /// `UserDefaults` and could in principle be planted from outside, but
    /// the credentials are in the Keychain under this app's own access
    /// group, which the XCUITest runner cannot write to.
    ///
    /// `accessToken` and `userID` are both populated deliberately —
    /// `AppState.start()` needs both before it will resume a cached session
    /// offline, so seeding only the username would make the `.offline`
    /// scenario fall through to the login screen instead.
    private static func seedSession() {
        let store = ServerSessionStore()
        store.saveServer(ServerConfiguration(
            name: UITestConfiguration.stubServerName,
            baseURL: UITestConfiguration.stubServerURL
        ))
        store.saveCredentials(StoredCredentials(
            username: UITestConfiguration.stubUsername,
            password: UITestConfiguration.stubPassword,
            accessToken: UITestConfiguration.stubAccessToken,
            userID: UITestConfiguration.stubUserID
        ))
    }
}
#endif
