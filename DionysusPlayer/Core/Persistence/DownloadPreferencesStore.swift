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
}
