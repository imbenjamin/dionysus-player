import SwiftUI

/// Switches between first-run setup, sign-in, and the main app based on
/// `AppState.phase`.
struct RootView: View {
    @Environment(AppState.self) private var appState
    /// Only meaningful while `appState.phase == .offline` — there's no tab
    /// bar/Profile tab reachable at this pre-`.main` phase, so the offline
    /// screen's "Go to Settings" flips this to swap in `ProfileView`
    /// directly (plain conditional branch, not `.sheet`/`.fullScreenCover`
    /// — see the `.offline` case below for why). `ProfileView` itself
    /// tolerates no signed-in `currentUser` yet (falls back to
    /// `sessionStore.credentials?.username`) and needs no network to
    /// render, so it's safe to show here even mid-outage.
    @State private var showingSettingsWhileOffline = false
    /// Same idea as `showingSettingsWhileOffline`, for the offline screen's
    /// "View Downloads" action — lets a genuinely cold, fully-offline
    /// launch (sign-in never completed this session, so `.main`/
    /// `MainTabView`'s own Downloads tab is unreachable) still reach
    /// offline-downloaded content. `DownloadsView` and everything it can
    /// push (`AppRoute.downloadedAsset`/`.downloadedShow`/`.downloadedSeason`,
    /// including playback) needs no live session at all.
    @State private var showingDownloadsWhileOffline = false

    var body: some View {
        Group {
            if appState.isRestoringSession {
                SplashView()
            } else {
                switch appState.phase {
                case .serverSetup:
                    ServerSetupView()
                case .login:
                    LoginView()
                case .main:
                    MainTabView()
                case .offline:
                    if showingSettingsWhileOffline {
                        NavigationStack {
                            ProfileView()
                                .toolbar {
                                    ToolbarItem(placement: .cancellationAction) {
                                        Button("Done") { showingSettingsWhileOffline = false }
                                    }
                                }
                        }
                    } else if showingDownloadsWhileOffline {
                        NavigationStack {
                            DownloadsView()
                                .navigationDestination(for: AppRoute.self, destination: AppRouteDestinationView.init)
                                .toolbar {
                                    ToolbarItem(placement: .cancellationAction) {
                                        Button("Done") { showingDownloadsWhileOffline = false }
                                    }
                                }
                        }
                    } else {
                        // Same plain-`Group`/switch pattern as the rest of
                        // this view, deliberately not `.sheet`/
                        // `.fullScreenCover` — this codebase avoids those
                        // at the root due to known `@Observable` re-render
                        // bugs (a presenter can stop re-running its body
                        // after an `@Observable` mutation underneath it).
                        OfflineStateView(
                            retry: { Task { await appState.start() } },
                            secondaryActionTitle: String(localized: "Go to Settings"),
                            secondaryAction: { showingSettingsWhileOffline = true },
                            tertiaryActionTitle: String(localized: "View Downloads"),
                            tertiaryAction: { showingDownloadsWhileOffline = true }
                        )
                    }
                }
            }
        }
        .animation(.default, value: appState.isRestoringSession)
        // Changing server/signing out from within the embedded Settings
        // screen moves `phase` away from `.offline` entirely, at which
        // point this flag is stale — reset it so a later fresh `.offline`
        // (e.g. after `changeServer()` circles back through `.login` and
        // fails to reach the new server too) starts from the offline
        // screen again, not straight back into Settings.
        .onChange(of: appState.phase) { _, _ in
            showingSettingsWhileOffline = false
            showingDownloadsWhileOffline = false
        }
    }
}

#Preview {
    RootView()
        .environment(AppState())
}
