import Foundation

/// Persisted via `@AppStorage(downloadResolutionStorageKey)` on
/// `DownloadsSettingsView`'s pickers — `DownloadResolution.deviceClassDefault`
/// is both that picker's own default and the default this store falls back
/// to when nothing's been saved yet, since an `@AppStorage` property's
/// default doesn't write anything to `UserDefaults` until the picker is
/// actually changed; both sides declaring the same default keeps them in
/// agreement pre-first-visit (same reasoning as `NextUpPreferenceStore`'s
/// own keys). **Both sides must be changed together** — they're declared
/// separately and nothing catches the drift.
let downloadResolutionStorageKey = "downloadResolutionPreference"
let downloadBitratePresetStorageKey = "downloadBitratePresetPreference"
/// Default `true` — an informed addition beyond what was originally asked
/// for: a multi-GB cellular transcode download is the single most common
/// way this kind of feature burns a user's data plan.
let downloadWifiOnlyStorageKey = "downloadWifiOnlyPreference"
/// Stored as a plain `Int` (the settings slider, `0...10`) rather than an
/// `Optional<Int>` — `@AppStorage`/`UserDefaults` have no native optional
/// representation, so `0` is the slider's own "Unlimited" sentinel, mapped
/// to `nil` by `maxConcurrentDownloads` below so every other call site
/// reasons about "no limit" the normal Swift way. Default `3` — a
/// deliberate choice to be considerate of the server by default rather
/// than Unlimited.
let downloadMaxConcurrentStorageKey = "downloadMaxConcurrentPreference"

/// Quality/network settings for offline downloads. Local to the device
/// only, like `NextUpPreferenceStore`/`TrackPreferenceStore`: plain
/// `UserDefaults`, not sensitive, never round-tripped through the server —
/// and, unlike those two, device-wide rather than scoped per Jellyfin user,
/// since a download's storage/bandwidth cost is a property of the device,
/// not of whoever's currently signed in.
///
/// Read-only and injectable, same shape as `NextUpPreferenceStore` —
/// `DownloadsSettingsView`'s own `@AppStorage` pickers/toggle are the only
/// writer, using the exact same keys, so non-view code (`DownloadManager`/
/// `DownloadButton`) can read the live setting without a SwiftUI
/// environment of their own.
struct DownloadPreferencesStore {
    private let defaults: UserDefaults
    private let fallbackResolution: DownloadResolution?

    /// `fallbackResolution` overrides `DownloadResolution.deviceClassDefault`
    /// for the pre-first-visit case. Production never passes it; it exists so
    /// tests can assert a fixed default instead of one that changes depending
    /// on whether the suite happens to be running on an iPhone or iPad
    /// simulator.
    init(defaults: UserDefaults = .standard, fallbackResolution: DownloadResolution? = nil) {
        self.defaults = defaults
        self.fallbackResolution = fallbackResolution
    }

    var resolution: DownloadResolution {
        defaults.string(forKey: downloadResolutionStorageKey).flatMap(DownloadResolution.init(rawValue:))
            ?? fallbackResolution
            ?? .deviceClassDefault
    }

    var bitratePreset: DownloadBitratePreset {
        defaults.string(forKey: downloadBitratePresetStorageKey).flatMap(DownloadBitratePreset.init(rawValue:)) ?? .normal
    }

    var wifiOnly: Bool {
        defaults.object(forKey: downloadWifiOnlyStorageKey) as? Bool ?? true
    }

    /// The most video downloads `DownloadManager` will run at once — `nil`
    /// means unlimited (see `downloadMaxConcurrentStorageKey`'s own doc
    /// comment). Only gates the actual background video transfer —
    /// subtitle/artwork fetches always run inline as soon as a download is
    /// requested, regardless of this limit, since they're small and quick.
    var maxConcurrentDownloads: Int? {
        let raw = defaults.object(forKey: downloadMaxConcurrentStorageKey) as? Int ?? 3
        return raw > 0 ? raw : nil
    }
}
