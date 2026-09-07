import Foundation

/// User-selectable countdown length for the in-player "Up Next" prompt
/// (`NextUpOverlay`) — how many seconds before an episode ends the prompt
/// appears. `.off` disables the whole feature: `NextUpPreferenceStore
/// .countdownSeconds` returns `nil`, which `PlayerViewModel
/// .nextUpSecondsRemaining` treats as "never show this," same as having no
/// next episode at all.
enum NextUpCountdownPreference: Int, CaseIterable, Identifiable, Codable {
    case off = 0
    case seconds15 = 15
    case seconds30 = 30
    case seconds45 = 45
    case seconds60 = 60

    var id: Int { rawValue }

    /// Kept short (`"15s"`, not `"15 Seconds"` — matching the "Playing in
    /// Xs" convention `NextUpOverlay` itself already uses) so the row still
    /// fits on one line in `ProfileView`'s `.menu`-style picker once
    /// `.seconds30` appends "(Default)" — the longer "X Seconds" form
    /// wrapped the picker's value onto a second line there.
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

    /// `displayName`'s spoken counterpart — VoiceOver reads a bare
    /// digit+"s" like "60s" as a shorthand decade ("Sixties"), not a
    /// duration, since that's a real, more common abbreviation pattern.
    /// Spells the unit out in full instead.
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

/// Persisted via `@AppStorage(nextUpCountdownStorageKey)` on `ProfileView`'s
/// picker. `30s` is both that picker's own default and the default this
/// store falls back to when nothing's been saved yet (an `@AppStorage`
/// property's default only applies locally within SwiftUI — it doesn't
/// write anything to `UserDefaults` until the picker is actually changed —
/// so both sides declaring the same default is what keeps them in agreement
/// pre-first-launch-visit; same reasoning as `hero3DDepthEnabledStorageKey`,
/// see `HeroHeaderView`'s doc comment on that one).
let nextUpCountdownStorageKey = "nextUpCountdownPreference"

/// Local to the device only, like `TrackPreferenceStore`/
/// `MediaVersionPreferenceStore`: plain `UserDefaults`, not sensitive, never
/// round-tripped through the server. Read-only and injectable (mirrors
/// `TrackPreferenceStore`'s `init(defaults:)` shape) so `PlayerViewModel`
/// can take one in its initializer and tests can point it at an isolated
/// `UserDefaults` suite.
struct NextUpPreferenceStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// `nil` means "never show the Up Next prompt" — either explicitly
    /// turned off, or an unrecognized/corrupt stored value (treated the
    /// same as unset, falling back to the default rather than failing).
    var countdownSeconds: Int? {
        guard let raw = defaults.object(forKey: nextUpCountdownStorageKey) as? Int,
              let preference = NextUpCountdownPreference(rawValue: raw) else {
            return NextUpCountdownPreference.seconds30.seconds
        }
        return preference.seconds
    }
}
