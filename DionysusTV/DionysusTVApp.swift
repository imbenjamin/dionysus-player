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
                .task {
                    // The unit-test host must not start a session: see
                    // `TestHostDetection`.
                    guard !TestHostDetection.isUnitTestHost else { return }
                    await appState.start()
                }
        }
    }
}

/// Where the user is in the app: `AppState.phase`, as on iOS.
struct TVRootView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase
    /// A `dionysus://` link (the Top Shelf's, M6, or one opened for
    /// debugging, #406), held until the session can take it, through
    /// sign-in if need be.
    @State private var pendingLink: PendingDeepLink?
    /// A link that couldn't be read arrived while the session restored (a
    /// cold launch from it): it's refused out loud once restoring ends.
    @State private var refusesUnreadableLinkAfterRestore = false

    var body: some View {
        Group {
            if appState.isRestoringSession {
                TVSplashView()
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
        // The splash crossfades into what follows it, as on iOS (`RootView`).
        .animation(.default, value: appState.isRestoringSession)
        .buttonStyle(TVOpaqueAtRestButtonStyle())
        .onOpenURL(perform: receive)
        .onChange(of: appState.isRestoringSession) { _, isRestoring in
            guard !isRestoring, refusesUnreadableLinkAfterRestore else { return }
            refusesUnreadableLinkAfterRestore = false
            if appState.phase == .main { ToastCenter.shared.post(.notice(DeepLink.cantOpenMessage)) }
        }
        .environment(\.tvPendingDeepLink, appliedLink)
        .environment(\.tvDeepLinkApplied, { pendingLink = nil })
        // The Top Shelf follows whoever last used Dionysus (M6).
        .onChange(of: appState.phase, initial: true) { mirrorSessionForTopShelf() }
        .onChange(of: appState.isRestoringSession) { mirrorSessionForTopShelf() }
        // tvOS suspends the app through sleep, so a long time away counts as
        // a relaunch: back to Who's Watching? when the settings ask
        // (`WhoIsWatchingPolicy`), closing the player first.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: appState.didEnterBackground()
            case .active:
                guard appState.asksWhoIsWatching(returningAt: Date()) else {
                    mirrorSessionForTopShelf()
                    return
                }
                TVPlayerPresenter.dismissPlayer()
                appState.signOut()
            default: break
            }
        }
    }

    private func mirrorSessionForTopShelf() {
        TopShelfRefresh.appStateChanged(
            isRestoringSession: appState.isRestoringSession,
            isSignedIn: appState.phase == .main,
            server: appState.sessionStore.serverConfiguration,
            credentials: appState.sessionStore.credentials
        )
    }

    /// A link replaces any still pending; one that can't be read is
    /// refused, out loud only where someone is signed in to see it (after
    /// the restore, for a cold launch from it).
    private func receive(_ url: URL) {
        guard let link = DeepLink(url: url) else {
            if appState.isRestoringSession {
                refusesUnreadableLinkAfterRestore = true
            } else if appState.phase == .main {
                ToastCenter.shared.post(.notice(DeepLink.cantOpenMessage))
            }
            return
        }
        pendingLink = PendingDeepLink(
            link: link, receivedAt: Date(), serverIDAtArrival: appState.sessionStore.serverConfiguration?.id
        )
    }

    /// The pending link once the router says it can go; a refused one is
    /// cleared here (saying why, where it says anything), a waiting one is
    /// kept until the session has restored or someone has signed in.
    private var appliedLink: DeepLink? {
        guard let pendingLink else { return nil }
        switch DeepLinkRouter.decide(
            pendingLink,
            now: Date(),
            isRestoringSession: appState.isRestoringSession,
            isSignedIn: appState.phase == .main,
            serverID: appState.sessionStore.serverConfiguration?.id,
            userID: appState.signedInUserID
        ) {
        case .wait, .waitForSignIn: return nil
        case .refuse(let refusal):
            Task { @MainActor in
                self.pendingLink = nil
                if let message = refusal.message { ToastCenter.shared.post(.notice(message)) }
            }
            return nil
        case .apply: return pendingLink.link
        }
    }
}

