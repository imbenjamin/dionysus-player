import Foundation

/// Per-device overrides to the download bitrate ladder
/// (`DownloadResolution.videoBitrate(preset:)`) that `DownloadsQualityLadderView`
/// lets a user dial in for themselves. The app's own tuned numbers (see
/// `DOWNLOADS.md`) remain the shipped default for every cell — this store
/// only ever holds the cells a user has deliberately changed away from that
/// default, keyed by resolution+preset. A cell with no override falls
/// through to `DownloadResolution.videoBitrate(preset:)` unchanged, so a
/// user who never opens the new Advanced screen sees byte-for-byte the same
/// behavior as before it existed.
///
/// Local to the device only, like `DownloadPreferencesStore`, which this
/// sits alongside: plain `UserDefaults`, not sensitive, never round-tripped
/// through the server, and device-wide rather than scoped per Jellyfin user
/// — a download's target bitrate is a property of the device storing it,
/// not of whoever's currently signed in.
///
/// All twelve cells (4 resolutions × 3 presets) live in a single JSON blob
/// under one key, same shape as `TrackPreferenceStore`'s own
/// dictionary-of-overrides storage — simpler than twelve separate
/// `UserDefaults` keys and makes "reset everything" a single
/// `removeObject(forKey:)` rather than twelve individual writes.
///
/// Values are stored and handed back in **Kbps** — what the settings UI
/// collects from and shows the user — and converted to bits/sec (what the
/// rest of the ladder, and Jellyfin's own API, deal in) only at
/// `videoBitrate(resolution:preset:)`, the one read site every real
/// download call routes through. Nothing else in the app needs to know the
/// storage unit.
struct DownloadQualityLadderStore {
    private static let storageKey = "downloadBitrateLadderOverridesKbps"

    /// A generous but real ceiling — purely to stop a fat-fingered value (an
    /// extra digit) from producing a nonsensical multi-hundred-megabit
    /// "download" nobody meant to request. Not a meaningful quality cap in
    /// its own right.
    static let maxKbps = 100_000
    /// `1`, not `0` — `0` would make `videoBitrate(resolution:preset:)`
    /// return 0 bits/sec, which Jellyfin has undefined behavior for, and
    /// reads to a user who fat-fingers an empty field as "off" rather than
    /// "extremely low quality."
    static let minKbps = 1

    private let defaults: UserDefaults
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func cellKey(_ resolution: DownloadResolution, _ preset: DownloadBitratePreset) -> String {
        "\(resolution.rawValue).\(preset.rawValue)"
    }

    private var overridesKbps: [String: Int] {
        guard let data = defaults.data(forKey: Self.storageKey),
              let overrides = try? decoder.decode([String: Int].self, from: data) else { return [:] }
        return overrides
    }

    /// The value the editor should show for this cell — the user's own
    /// override if they've set one, else the shipped default converted from
    /// `DownloadResolution.videoBitrate(preset:)`'s bits/sec.
    func kbps(resolution: DownloadResolution, preset: DownloadBitratePreset) -> Int {
        overridesKbps[cellKey(resolution, preset)] ?? resolution.videoBitrate(preset: preset) / 1000
    }

    func isOverridden(resolution: DownloadResolution, preset: DownloadBitratePreset) -> Bool {
        overridesKbps[cellKey(resolution, preset)] != nil
    }

    /// Whether *any* cell has been changed away from its default — drives
    /// whether the settings screen's "Reset All to Defaults" action is
    /// enabled.
    var hasAnyOverride: Bool { !overridesKbps.isEmpty }

    /// The bits/sec value the rest of the download pipeline should actually
    /// use for this cell. `DownloadTranscodeCalculator.target(...)`/
    /// `JellyfinAPIClient.downloadStreamURL` are given this as their
    /// `videoBitrateLadder` closure instead of calling
    /// `DownloadResolution.videoBitrate(preset:)` directly, so a user's
    /// override actually reaches a real download, not just the settings UI
    /// that edits it.
    func videoBitrate(resolution: DownloadResolution, preset: DownloadBitratePreset) -> Int {
        kbps(resolution: resolution, preset: preset) * 1000
    }

    /// `nil` clears this one cell back to the shipped default. A non-nil
    /// value is clamped to `minKbps...maxKbps` before being stored — and, if
    /// that clamped value turns out to exactly equal the shipped default,
    /// treated the same as `nil` rather than stored as a redundant
    /// "override" that isn't actually overriding anything. That equality
    /// check isn't just tidiness: `DownloadsQualityLadderView`'s per-row
    /// `TextField` bindings are recreated fresh on every render (a `Binding`
    /// closure pair has no stable identity of its own to persist across
    /// renders), and SwiftUI can resync a recreated `Binding` by writing its
    /// current displayed value straight back through the new `set` —
    /// confirmed live: resetting a field, then editing an unrelated one
    /// elsewhere on the same screen (forcing every row's body, and thus
    /// every row's `Binding`, to re-evaluate) silently re-persisted the
    /// just-cleared cell as an explicit override of its own default value,
    /// which then wrongly showed a "reset" affordance for a cell with
    /// nothing left to reset. Collapsing an at-default write to a clear
    /// makes every such spurious resync a safe no-op regardless of how many
    /// times it fires, rather than chasing the resync itself.
    func setOverride(_ kbps: Int?, resolution: DownloadResolution, preset: DownloadBitratePreset) {
        var overrides = overridesKbps
        if let kbps {
            let clamped = min(max(kbps, Self.minKbps), Self.maxKbps)
            if clamped == resolution.videoBitrate(preset: preset) / 1000 {
                overrides.removeValue(forKey: cellKey(resolution, preset))
            } else {
                overrides[cellKey(resolution, preset)] = clamped
            }
        } else {
            overrides.removeValue(forKey: cellKey(resolution, preset))
        }
        save(overrides)
    }

    /// Clears every override in one call — the settings screen's "Reset All
    /// to Defaults" action.
    func resetAll() {
        defaults.removeObject(forKey: Self.storageKey)
    }

    private func save(_ overrides: [String: Int]) {
        guard let data = try? encoder.encode(overrides) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
