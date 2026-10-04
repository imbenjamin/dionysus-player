import SwiftUI

/// The signed-in app, or everything before it — splash, welcome, server setup
/// and sign-in, which `OnboardingFlowView` presents as one continuous scene.
struct RootView: View {
    @Environment(AppState.self) private var appState

    private var isInMainApp: Bool {
        !appState.isRestoringSession && appState.phase == .main
    }

    var body: some View {
        Group {
            if isInMainApp {
                MainTabView()
            } else {
                OnboardingFlowView()
            }
        }
        .animation(.default, value: isInMainApp)
    }
}

#Preview {
    RootView()
        .environment(AppState())
}
