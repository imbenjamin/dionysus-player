import Foundation

/// Per-device overrides to the download bitrate ladder, as
/// `DownloadsQualityLadderView` lets a user set them. Holds only the cells a
/// user has changed, keyed by resolution and preset; a cell with no override
/// falls through to `DownloadResolution.videoBitrate(preset:)`, so a user who
/// never opens that screen sees the shipped behaviour exactly.
///
/// Device-local `UserDefaults`, never round-tripped through the server, and
/// device-wide rather than per Jellyfin user: a download's target bitrate is a
/// property of the device storing it.
///
/// All twelve cells live in one JSON blob under a single key, which makes
/// "reset everything" one `removeObject(forKey:)` instead of twelve writes.
///
/// Stored and returned in Kbps, the unit the settings UI collects, and converted
/// to bits/sec only in `videoBitrate(resolution:preset:)`.
struct DownloadQualityLadderStore {
    private static let storageKey = "downloadBitrateLadderOverridesKbps"

    /// A ceiling against a fat-fingered extra digit producing a
    /// multi-hundred-megabit download, not a meaningful quality cap.
    static let maxKbps = 100_000
    /// `1`, not `0`: zero bits/sec is undefined behaviour for Jellyfin, and
    /// reads to a user as "off" rather than "extremely low quality".
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

    /// What the editor shows for this cell: the user's override, else the
    /// shipped default converted from bits/sec.
    func kbps(resolution: DownloadResolution, preset: DownloadBitratePreset) -> Int {
        overridesKbps[cellKey(resolution, preset)] ?? resolution.videoBitrate(preset: preset) / 1000
    }

    func isOverridden(resolution: DownloadResolution, preset: DownloadBitratePreset) -> Bool {
        overridesKbps[cellKey(resolution, preset)] != nil
    }

    /// Whether any cell differs from its default, enabling "Reset All to
    /// Defaults".
    var hasAnyOverride: Bool { !overridesKbps.isEmpty }

    /// The bits/sec the download pipeline uses for this cell. Passed to
    /// `DownloadTranscodeCalculator.target(...)` and `downloadStreamURL` as their
    /// `videoBitrateLadder`, so an override reaches a real download rather than
    /// only the settings UI.
    func videoBitrate(resolution: DownloadResolution, preset: DownloadBitratePreset) -> Int {
        kbps(resolution: resolution, preset: preset) * 1000
    }

    /// `nil` clears the cell back to the shipped default. A non-nil value is
    /// clamped to `minKbps...maxKbps`, and a clamped value equal to the default
    /// is treated as `nil` rather than stored as an override that overrides
    /// nothing.
    ///
    /// That equality check is load-bearing.
    /// `DownloadsQualityLadderView`'s per-row `TextField` bindings are recreated
    /// on every render, having no stable identity, and SwiftUI can resync a
    /// recreated `Binding` by writing its displayed value back through the new
    /// `set`. Editing one field re-evaluates every row's body, which silently
    /// re-persisted a just-cleared cell as an explicit override of its own
    /// default and left a "reset" affordance with nothing to reset. Collapsing
    /// an at-default write to a clear makes every such resync a safe no-op.
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

    /// Clears every override, for "Reset All to Defaults".
    func resetAll() {
        defaults.removeObject(forKey: Self.storageKey)
    }

    private func save(_ overrides: [String: Int]) {
        guard let data = try? encoder.encode(overrides) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
