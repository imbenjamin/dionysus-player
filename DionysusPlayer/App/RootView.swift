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
                            secondaryAction: { showingSettingsWhileOffline = true }
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
        .onChange(of: appState.phase) { _, _ in showingSettingsWhileOffline = false }
    }
}

#Preview {
    RootView()
        .environment(AppState())
}
