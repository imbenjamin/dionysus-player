import Foundation

/// How the app's own overlay draws text subtitles (Profile → Playback →
/// Subtitle Style; Benjamin, 2026-10-30). Bitmap subtitles and libass's
/// styled ASS are never restyled, whichever is chosen.
enum SubtitleAppearance: String, CaseIterable, Identifiable, Codable {
    /// The app's own look (`SubtitleTextStyle.dionysus`).
    case dionysus
    /// Settings › Accessibility › Subtitles & Captioning, over the app's own
    /// look for anything left at the system's default. The default: someone
    /// who never touched that page sees the Dionysus look either way, and
    /// someone who did chose it on purpose.
    case system

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dionysus: String(localized: "Dionysus")
        case .system: String(localized: "System (Default)")
        }
    }
}

/// Persisted via `@AppStorage` on both platforms' settings and read by
/// `SubtitleOverlayView`. An `@AppStorage` default writes nothing to
/// `UserDefaults` until the picker changes, so every site declares
/// `subtitleAppearanceDefault`.
let subtitleAppearanceStorageKey = "subtitleAppearance"
let subtitleAppearanceDefault = SubtitleAppearance.system
