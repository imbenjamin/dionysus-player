import Foundation

/// Persisted via `@AppStorage(downloadResolutionStorageKey)` on
/// `ProfileView`'s Downloads section pickers — `.hd1080p` is both that
/// picker's own default and the default this store falls back to when
/// nothing's been saved yet (an `@AppStorage` property's default only
/// applies locally within SwiftUI — it doesn't write anything to
/// `UserDefaults` until the picker is actually changed — so both sides
/// declaring the same default is what keeps them in agreement pre-first-
/// launch-visit; same reasoning as `nextUpCountdownStorageKey`, see
/// `NextUpPreferenceStore`'s doc comment).
let downloadResolutionStorageKey = "downloadResolutionPreference"
let downloadBitratePresetStorageKey = "downloadBitratePresetPreference"
/// Default `true` — an informed addition beyond what was originally asked
/// for: a multi-GB cellular transcode download is the single most common
/// way this kind of feature burns a user's data plan.
let downloadWifiOnlyStorageKey = "downloadWifiOnlyPreference"
/// Stored as a plain `Int` (`ProfileView`'s slider, `0...10`) rather than an
/// `Optional<Int>` — `@AppStorage`/`UserDefaults` have no native optional
/// representation, so `0` is the slider's own "Unlimited" sentinel, mapped
/// to `nil` by `maxConcurrentDownloads` below so every other call site
/// reasons about "no limit" the normal Swift way instead of a magic number
/// leaking out of this file. Default `5` (both here and on the slider
/// itself, same "both sides declare the same default" reasoning as
/// `downloadResolutionStorageKey` above) — a deliberate, explicit choice to
/// be considerate of the server by default rather than defaulting to
/// Unlimited, which was this feature's original (undeliberate) behavior.
let downloadMaxConcurrentStorageKey = "downloadMaxConcurrentPreference"

/// Quality/network settings for offline downloads. Local to the device
/// only, like `NextUpPreferenceStore`/`TrackPreferenceStore`: plain
/// `UserDefaults`, not sensitive, never round-tripped through the server —
/// and, unlike those two, device-wide rather than scoped per Jellyfin user,
/// since a download's storage/bandwidth cost is a property of the device,
/// not of whoever's currently signed in.
///
/// Read-only and injectable, same shape as `NextUpPreferenceStore` —
/// `ProfileView`'s own `@AppStorage` pickers/toggle are the only writer,
/// using the exact same keys, so non-view code (`DownloadManager`/
/// `DownloadButton`) can read the live setting without a SwiftUI
/// environment of their own.
struct DownloadPreferencesStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var resolution: DownloadResolution {
        defaults.string(forKey: downloadResolutionStorageKey).flatMap(DownloadResolution.init(rawValue:)) ?? .hd1080p
    }

    var bitratePreset: DownloadBitratePreset {
        defaults.string(forKey: downloadBitratePresetStorageKey).flatMap(DownloadBitratePreset.init(rawValue:)) ?? .normal
    }

    var wifiOnly: Bool {
        defaults.object(forKey: downloadWifiOnlyStorageKey) as? Bool ?? true
    }

    /// The most video downloads `DownloadManager` will run at once — `nil`
    /// means unlimited (only reachable by deliberately dragging
    /// `ProfileView`'s slider all the way to "Unlimited"; `5` is the default
    /// for anyone who hasn't visited it yet, see `downloadMaxConcurrentStorageKey`'s
    /// own doc comment). Only gates the actual background video transfer —
    /// subtitle/artwork fetches always run inline as soon as a download is
    /// requested, regardless of this limit, since they're small and quick.
    var maxConcurrentDownloads: Int? {
        let raw = defaults.object(forKey: downloadMaxConcurrentStorageKey) as? Int ?? 5
        return raw > 0 ? raw : nil
    }
}
