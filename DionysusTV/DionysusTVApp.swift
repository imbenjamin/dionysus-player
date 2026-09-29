import SwiftUI

@main
struct DionysusTVApp: App {
    @State private var appState = AppState()

    init() {
        #if DEBUG
        UITestHarness.installIfNeeded()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            TVRootView()
                .environment(appState)
                .task { await appState.start() }
        }
    }
}

/// Where the user is in the app: `AppState.phase`, as on iOS. Task 4 replaces
/// the placeholders with the onboarding screens and the browse launcher.
struct TVRootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            if appState.isRestoringSession {
                ProgressView()
            } else {
                switch appState.phase {
                case .serverSetup:
                    Text("Find Your Server").accessibilityIdentifier(A11yID.TV.Onboarding.findServerTitle)
                case .login: Text("Who's Watching?")
                case .main: Text("Home")
                }
            }
        }
    }
}
