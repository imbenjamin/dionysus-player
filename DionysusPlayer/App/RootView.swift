import SwiftUI

/// Switches between first-run setup, sign-in, and the main app based on
/// `AppState.phase`.
struct RootView: View {
    @Environment(AppState.self) private var appState

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
                }
            }
        }
        .animation(.default, value: appState.isRestoringSession)
    }
}

#Preview {
    RootView()
        .environment(AppState())
}
