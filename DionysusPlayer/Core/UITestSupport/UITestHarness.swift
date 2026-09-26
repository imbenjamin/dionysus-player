#if DEBUG
import Foundation
import SwiftUI
import UIKit

/// Puts the app into the deterministic state a UI test expects, before any
/// of it has been read.
///
/// Ordering is the point of this type. `DionysusPlayerApp` builds `AppState`
/// eagerly, and `AppState.init` builds a `ServerSessionStore` that reads
/// `UserDefaults` and the Keychain in its own initializer. Reset and seeding
/// must therefore happen in `DionysusPlayerApp.init()`, not in a `.task` or
/// `.onAppear` that runs after the store has already loaded the previous run's
/// leftovers.
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

        if UITestConfiguration.seedsLongSearchHistory {
            seedLongSearchHistory()
        }

        if UITestConfiguration.disablesAnimations {
            UIView.setAnimationsEnabled(false)
        }
    }

    /// Inserts the stub into a session configuration the app builds itself.
    ///
    /// `URLProtocol.registerClass` only reaches `URLSession.shared`, which covers
    /// `JellyfinAPIClient` but not `RemoteImageLoader` or `DownloadManager`, both
    /// of which configure their own sessions and call this instead. A no-op
    /// outside a UI test run, so call sites stay unconditional.
    ///
    /// `nonisolated` because those callers aren't on the main actor. Touches only
    /// the configuration passed in.
    nonisolated static func decorate(_ configuration: URLSessionConfiguration) {
        guard UITestConfiguration.isActive else { return }
        configuration.protocolClasses = [UITestStubURLProtocol.self] + (configuration.protocolClasses ?? [])
    }

    /// Keeps the player's controls on screen. `PlayerView`'s auto-hide timer
    /// otherwise races every assertion: the overlay hides 3s after the last
    /// interaction unless VoiceOver is running, which XCUITest doesn't enable.
    nonisolated static var keepsPlayerControlsVisible: Bool {
        UITestConfiguration.isActive && UITestConfiguration.disablesControlAutoHide
    }

    /// Holds the pre-sign-in journey's ambient motion still — the drifting
    /// background and the scan radar. Continuously
    /// redrawing views keep the accessibility tree in motion under every
    /// assertion, the same reason the hero carousel and 3D depth are switched
    /// off from `UITestCase.launch`.
    nonisolated static var freezesAmbientMotion: Bool {
        UITestConfiguration.isActive && UITestConfiguration.disablesAnimations
    }

    // MARK: - State

    /// Clears everything surviving a relaunch, so one test can't see another's
    /// leftovers. The Keychain matters most: it outlives the app container, so a
    /// signed-in run would otherwise seed every later first-launch test.
    private static func resetPersistentState() {
        ServerSessionStore().clearAll()

        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }

        // Downloaded media lives outside `UserDefaults`: SwiftData rows in
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

    /// Plants a server and signed-in session so a test starts at
    /// `AppState.Phase.main`.
    ///
    /// In-process because the credentials live in the Keychain under this app's
    /// access group, which the XCUITest runner can't write to.
    ///
    /// Both `accessToken` and `userID` are populated: `AppState.start()` needs
    /// both to resume a cached session offline, so seeding only the username
    /// would drop the `.offline` scenario to the login screen.
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

    /// Records one entry more than `SearchHistoryStore` keeps, so the list ends
    /// at the store's own cap rather than a count this has to track. Placeholder
    /// ids with no image tags: the entries only need to take up space, and a
    /// tag would send a request the stub has no fixture for.
    private static func seedLongSearchHistory() {
        let store = SearchHistoryStore()
        for index in 1...21 {
            let hint = SearchHint(id: "uitest-history-\(index)", name: "Recent Search \(index)", type: .movie, productionYear: 2000 + index)
            store.record(SearchResult(hint: hint), userID: UITestConfiguration.stubUserID)
        }
    }
}
#endif
