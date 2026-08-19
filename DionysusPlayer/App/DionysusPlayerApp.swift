import SwiftUI

/// User-selectable appearance override. `.system` (the default) defers to
/// iOS's own light/dark setting; the other cases force a specific scheme.
/// Persisted via `@AppStorage(themePreferenceStorageKey)`.
enum ThemePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return String(localized: "System")
        case .light:  return String(localized: "Light")
        case .dark:   return String(localized: "Dark")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

let themePreferenceStorageKey = "themePreference"

@main
struct DionysusPlayerApp: App {
    // Only needed to answer UIKit's
    // `application(_:supportedInterfaceOrientationsFor:)` for the player's
    // rotation-lock button (see `AppDelegate`/`RotationLock`) — SwiftUI's
    // `App` protocol has no hook for that itself.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()
    @AppStorage(themePreferenceStorageKey) private var themePreference: ThemePreference = .system
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .preferredColorScheme(themePreference.colorScheme)
                .task {
                    await appState.start()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    // Cheap unauthenticated reachability probe on every
                    // foreground transition (covers both "resume" and
                    // "return from background" — ScenePhase doesn't
                    // distinguish them). `healthCheck()` — Jellyfin's own
                    // purpose-built liveness endpoint — rather than
                    // `publicSystemInfo()`, which fetches and decodes a
                    // full JSON payload just to prove reachability. The
                    // result is discarded either way; the point is
                    // sendRaw's success/failure side effect on
                    // ConnectivityMonitor. Firing again on the very first
                    // activation alongside appState.start()'s own real
                    // request is harmless.
                    guard newPhase == .active, let client = appState.apiClient else { return }
                    Task {
                        try? await client.healthCheck()
                        // Piggybacks on this same reconnect check rather
                        // than its own trigger — see
                        // `DownloadSyncManager`'s doc comment. Only
                        // meaningful once `healthCheck()` above has had a
                        // chance to clear `ConnectivityMonitor.isOffline`
                        // if reachability was actually just restored.
                        guard !ConnectivityMonitor.shared.isOffline else { return }
                        await DownloadSyncManager.syncIfNeeded(client: client, store: appState.downloadManager.store)
                    }
                }
        }
    }
}
