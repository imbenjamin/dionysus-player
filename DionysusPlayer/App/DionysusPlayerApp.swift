import SwiftUI

@main
struct DionysusPlayerApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .task {
                    await appState.start()
                }
        }
    }
}
