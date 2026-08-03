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
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
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
    @State private var appState = AppState()
    @AppStorage(themePreferenceStorageKey) private var themePreference: ThemePreference = .system

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .preferredColorScheme(themePreference.colorScheme)
                .task {
                    await appState.start()
                }
        }
    }
}
