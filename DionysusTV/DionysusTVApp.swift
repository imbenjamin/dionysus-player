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
        // Before anything can raise a TLS challenge (#466), and after the
        // harness, so it reads the store a test reset or seeded. The same
        // store `AppState` makes.
        ServerTrustEngineBridge.install()
        ServerTrustRegistry.shared.loadFromStore(ServerSessionStore())
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
    /// A `server?url=` link's address (DEBUG builds only), for Find Your
    /// Server to fill in; cleared once setup is left.
    @State private var linkedServerAddress: LinkedServerAddress?

    var body: some View {
        Group {
            if appState.isRestoringSession {
                TVSplashView()
            } else {
                switch appState.phase {
                case .serverSetup:
                    if appState.sessionStore.hasCompletedWelcome || linkedServerAddress != nil {
                        TVServerSetupView(linkedAddress: linkedServerAddress)
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
        // A refused certificate for the configured server (#466), over
        // everything, but never over a player: playback fails with a
        // message of its own and the page shows once the player has gone.
        .certificateWarning(
            isPlayerUp: { TVPlayerActivity.shared.isPlayerUp },
            // The player's host, and whatever is over it, is never dismissed.
            protects: { $0 is TVPlayerPresentation }
        ) { warning, answer in
            TVCertificateWarningPage(
                warning: warning,
                serverName: appState.sessionStore.serverConfiguration?.name ?? "",
                host: appState.sessionStore.serverConfiguration?.baseURL.host,
                onAnswer: answer
            )
        }
        .onOpenURL(perform: receive)
        .onChange(of: appState.isRestoringSession) { _, isRestoring in
            guard !isRestoring, refusesUnreadableLinkAfterRestore else { return }
            refusesUnreadableLinkAfterRestore = false
            if appState.phase == .main { ToastCenter.shared.post(.notice(DeepLink.cantOpenMessage)) }
        }
        // Server setup is before the main app, so the root applies it.
        .onChange(of: appliedLink, initial: true) { _, link in
            guard case .serverSetup(let address)? = link?.destination else { return }
            linkedServerAddress = LinkedServerAddress(address: address)
            pendingLink = nil
        }
        .onChange(of: appState.phase) { _, phase in
            if phase != .serverSetup { linkedServerAddress = nil }
        }
        .environment(\.tvPendingDeepLink, appliedLink)
        .environment(\.tvDeepLinkApplied, { pendingLink = nil })
        // The Top Shelf follows whoever last used Dionysus (M6).
        .onChange(of: appState.phase, initial: true) { mirrorSessionForTopShelf() }
        .onChange(of: appState.isRestoringSession) { mirrorSessionForTopShelf() }
        // Trusting a new certificate from `.main` changes neither of those,
        // and the extension decides against the mirrored trust (#466). The
        // trust is saved before the restart signs in again, so the token the
        // sign-in saves after it is mirrored too: the old one may be revoked.
        // (`TopShelfRefresh` writes nothing while a launch restores.)
        .onChange(of: appState.sessionStore.serverConfiguration?.certificateTrust) { mirrorSessionForTopShelf() }
        .onChange(of: appState.sessionStore.credentials?.accessToken) { mirrorSessionForTopShelf() }
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
                // Toasts show only in the signed-in app.
                if let message = refusal.message, appState.phase == .main { ToastCenter.shared.post(.notice(message)) }
            }
            return nil
        case .apply: return pendingLink.link
        }
    }
}

