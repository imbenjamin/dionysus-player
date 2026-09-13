import Foundation

/// How many seconds before an episode ends `NextUpOverlay` appears. `.off`
/// disables the feature: `countdownSeconds` returns `nil`, which
/// `PlayerViewModel.nextUpSecondsRemaining` treats as having no next episode.
enum NextUpCountdownPreference: Int, CaseIterable, Identifiable, Codable {
    case off = 0
    case seconds15 = 15
    case seconds30 = 30
    case seconds45 = 45
    case seconds60 = 60

    var id: Int { rawValue }

    /// Short form ("15s"), matching `NextUpOverlay`'s own "Playing in Xs", so
    /// the row still fits one line in `ProfileView`'s picker once `.seconds30`
    /// appends "(Default)". The longer form wrapped onto a second line.
    var displayName: String {
        switch self {
        case .off:        return String(localized: "Off")
        case .seconds15:  return String(localized: "15s")
        case .seconds30:  return String(localized: "30s (Default)")
        case .seconds45:  return String(localized: "45s")
        case .seconds60:  return String(localized: "60s")
        }
    }

    var seconds: Int? { self == .off ? nil : rawValue }

    /// `displayName`'s spoken counterpart, spelling the unit out: VoiceOver reads
    /// "60s" as a decade, that being the commoner abbreviation.
    var accessibilityLabel: String {
        switch self {
        case .off:        String(localized: "Off")
        case .seconds15:  String(localized: "15 seconds")
        case .seconds30:  String(localized: "30 seconds (Default)")
        case .seconds45:  String(localized: "45 seconds")
        case .seconds60:  String(localized: "60 seconds")
        }
    }
}

/// Persisted via `@AppStorage` on `ProfileView`'s picker. `30s` is both that
/// picker's default and this store's fallback: an `@AppStorage` default applies
/// only within SwiftUI and writes nothing to `UserDefaults` until the picker
/// changes, so both sides must declare it.
let nextUpCountdownStorageKey = "nextUpCountdownPreference"

/// Device-local `UserDefaults`, never round-tripped through the server.
/// Read-only and injectable, so `PlayerViewModel` can take one and tests can
/// point it at an isolated suite.
struct NextUpPreferenceStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// `nil` never shows the prompt. An unrecognized stored value is treated as
    /// unset and falls back to the default rather than failing.
    var countdownSeconds: Int? {
        guard let raw = defaults.object(forKey: nextUpCountdownStorageKey) as? Int,
              let preference = NextUpCountdownPreference(rawValue: raw) else {
            return NextUpCountdownPreference.seconds30.seconds
        }
        return preference.seconds
    }
}
