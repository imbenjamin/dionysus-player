import Foundation

/// Persisted via `@AppStorage` on `DownloadsSettingsView`'s pickers.
/// `DownloadResolution.deviceClassDefault` is both that picker's default and
/// this store's fallback, since an `@AppStorage` default writes nothing to
/// `UserDefaults` until the picker changes. **Both sides must change
/// together** — nothing catches the drift.
let downloadResolutionStorageKey = "downloadResolutionPreference"
let downloadBitratePresetStorageKey = "downloadBitratePresetPreference"
/// Defaults on: a multi-GB cellular transcode download is the commonest way
/// this kind of feature burns a data plan.
let downloadWifiOnlyStorageKey = "downloadWifiOnlyPreference"
/// A plain `Int` from the settings slider rather than an `Optional<Int>`, which
/// `@AppStorage` can't represent, so `0` is the slider's "Unlimited" sentinel
/// and `maxConcurrentDownloads` maps it to `nil` for every other call site. The
/// default is considerate of the server rather than unlimited.
let downloadMaxConcurrentStorageKey = "downloadMaxConcurrentPreference"

/// Quality and network settings for offline downloads. Device-local
/// `UserDefaults`, never round-tripped through the server, and — unlike the
/// per-user stores — device-wide, since a download's storage and bandwidth cost
/// is a property of the device.
///
/// Read-only and injectable. `DownloadsSettingsView`'s `@AppStorage` controls
/// are the only writer, using the same keys, so non-view code can read the live
/// setting with no SwiftUI environment.
struct DownloadPreferencesStore {
    private let defaults: UserDefaults
    private let fallbackResolution: DownloadResolution?

    /// `fallbackResolution` overrides `deviceClassDefault` before a first visit.
    /// Production never passes it; tests do, to assert a fixed default rather
    /// than one that varies by simulator.
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

    /// The most video downloads to run at once; `nil` is unlimited. Gates only
    /// the background video transfer — subtitle and artwork fetches run inline
    /// whatever this says, being small and quick.
    var maxConcurrentDownloads: Int? {
        let raw = defaults.object(forKey: downloadMaxConcurrentStorageKey) as? Int ?? 3
        return raw > 0 ? raw : nil
    }
}
