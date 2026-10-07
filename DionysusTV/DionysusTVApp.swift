import SwiftUI

@main
struct DionysusTVApp: App {
    @State private var appState: AppState

    /// `AppState` is built here, after the UI-test harness, as on iOS
    /// (`DionysusPlayerApp.init`): its `ServerSessionStore` reads the keychain
    /// as it's made, so a test's reset and seeded session must land first. As
    /// a property default it was built before this ran, and each launch saw
    /// the previous one's session (every journey failed on CI's fresh
    /// Simulator; locally the timing hid it).
    init() {
        // Jellyfin names this Apple TV from it on every request; the iOS app
        // primes it from its AppDelegate, which tvOS doesn't have.
        DeviceIdentity.primeCache()
        #if DEBUG
        UITestHarness.installIfNeeded()
        #endif
        _appState = State(initialValue: AppState())
    }

    var body: some Scene {
        WindowGroup {
            TVRootView()
                .environment(appState)
                .task { await appState.start() }
        }
    }
}

/// Where the user is in the app: `AppState.phase`, as on iOS.
struct TVRootView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if appState.isRestoringSession {
                ProgressView()
            } else {
                switch appState.phase {
                case .serverSetup:
                    if appState.sessionStore.hasCompletedWelcome {
                        TVServerSetupView()
                    } else {
                        TVWelcomeView()
                    }
                case .login: TVLoginView()
                case .main:
                    // `signedInUserID`, not `currentUser`: a launch resumed from
                    // cache has no `currentUser` yet, and this drew nothing.
                    if let client = appState.apiClient, let userID = appState.signedInUserID {
                        TVMainView(client: client, userID: userID)
                    }
                }
            }
        }
        // tvOS suspends the app through sleep, so a long time away counts as
        // a relaunch: back to Who's Watching? when the settings ask
        // (`WhoIsWatchingPolicy`), closing the player first.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: appState.didEnterBackground()
            case .active:
                guard appState.asksWhoIsWatching(returningAt: Date()) else { return }
                TVPlayerPresenter.dismissPlayer()
                appState.signOut()
            default: break
            }
        }
    }
}
