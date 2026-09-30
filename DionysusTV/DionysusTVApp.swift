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

/// Where the user is in the app: `AppState.phase`, as on iOS.
struct TVRootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            if appState.isRestoringSession {
                ProgressView()
            } else {
                switch appState.phase {
                case .serverSetup: TVServerSetupView()
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
    }
}
