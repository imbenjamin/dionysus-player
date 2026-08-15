import Foundation

/// Remembers the audio/subtitle tracks a user explicitly picked for an item
/// during a previous playback session, so returning to it later restores
/// those choices instead of falling through the engine's own default/
/// forced-subtitle selection every time — see `PlayerViewModel
/// .applyStoredTrackSelection()`'s doc comment for how this interacts with
/// `AetherPlaybackEngine`'s forced-subtitle auto-select.
///
/// Local to the device only, like `MediaVersionPreferenceStore`: plain
/// `UserDefaults`, not sensitive, never round-tripped through the server,
/// scoped per user for the same shared-device reasoning. Keyed by item id
/// alone (not media source) — same scoping as `MediaVersionPreferenceStore`.
final class TrackPreferenceStore {
    /// A track as it looked at the moment it was chosen. `id` alone isn't
    /// enough to safely restore later: AetherEngine/Jellyfin track ids are
    /// just physical container positions, not stable identifiers, so the
    /// same id next time could belong to a completely different track (a
    /// different version resolved, a re-mux, reordered streams — no track
    /// count needs to change for this to happen). `title` is carried
    /// alongside as a cheap sanity check — `PlayerViewModel
    /// .applyStoredTrackSelection()` only restores an id whose current
    /// track still has this same title, and skips (falls back to the
    /// engine's own default) on a mismatch, same as an id gone missing
    /// outright.
    struct TrackChoice: Codable, Equatable {
        var id: Int
        var title: String
    }

    /// One item's remembered choice. `audioTrack == nil` means audio was
    /// never explicitly picked (leave the engine's own default alone).
    /// `subtitlePreference` is a real tri-state rather than a nested
    /// optional: no explicit choice yet, deliberately turned off, or a
    /// specific track — "off" is as meaningful a remembered choice as any
    /// track, distinct from "nothing recorded."
    struct TrackSelection: Codable, Equatable {
        enum SubtitlePreference: Codable, Equatable {
            case unset
            case off
            case track(TrackChoice)
        }

        var audioTrack: TrackChoice?
        var subtitlePreference: SubtitlePreference = .unset
    }

    private let defaults: UserDefaults
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(userID: String) -> String { "playback.trackPreference.\(userID)" }

    func selection(forItem itemID: String, userID: String) -> TrackSelection? {
        preferences(userID: userID)[itemID]
    }

    func recordAudioSelection(_ track: TrackChoice, forItem itemID: String, userID: String) {
        var prefs = preferences(userID: userID)
        var selection = prefs[itemID] ?? TrackSelection()
        selection.audioTrack = track
        prefs[itemID] = selection
        save(prefs, userID: userID)
    }

    /// `nil` records "off" as a deliberate choice, same as
    /// `PlaybackEngine.selectSubtitleTrack(id:)`'s own `nil` meaning.
    func recordSubtitleSelection(_ track: TrackChoice?, forItem itemID: String, userID: String) {
        var prefs = preferences(userID: userID)
        var selection = prefs[itemID] ?? TrackSelection()
        selection.subtitlePreference = track.map { .track($0) } ?? .off
        prefs[itemID] = selection
        save(prefs, userID: userID)
    }

    private func preferences(userID: String) -> [String: TrackSelection] {
        guard let data = defaults.data(forKey: key(userID: userID)),
              let prefs = try? decoder.decode([String: TrackSelection].self, from: data) else { return [:] }
        return prefs
    }

    private func save(_ prefs: [String: TrackSelection], userID: String) {
        guard let data = try? encoder.encode(prefs) else { return }
        defaults.set(data, forKey: key(userID: userID))
    }
}
