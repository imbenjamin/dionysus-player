import Foundation

/// Remembers the audio and subtitle tracks a user explicitly picked for an item,
/// so returning to it restores those choices rather than falling through the
/// engine's default and forced-subtitle selection each time.
///
/// Device-local `UserDefaults`, never round-tripped through the server.
/// Jellyfin's own `UserItemData.AudioStreamIndex`/`SubtitleStreamIndex` was
/// rejected for this: the corresponding `MediaSourceInfo.Default*StreamIndex`
/// fields are always populated by a language-preference fallback even when the
/// user chose nothing, and the field distinguishing the two cases
/// (`AudioIndexSource`) is `[JsonIgnore]`d server-side with no subtitle
/// equivalent at all. A client would still need the local validation this store
/// does, so the round-trip adds cost without safety.
///
/// Keyed by item id alone — not media source, not live versus downloaded. It is
/// the same item either way, and `PlayerViewModel.start()`/`.startOffline()`
/// share one entry. Do not add a `mediaSourceID` or context parameter.
///
/// That sharing does not mean a subtitle choice reliably restores across the
/// live/downloaded boundary. A download transcodes to a more limited source, and
/// a downloaded track's title comes from Jellyfin's `MediaStream.displayTitle`
/// while an embedded track's live title comes from AetherEngine's container
/// metadata, so the two often disagree.
/// `PlayerViewModel.applyStoredTrackSelection()`'s strict id-and-title match
/// then declines to restore, as it would for any stale entry. Fixing it would
/// mean plumbing a title-independent identity — a language code — through both
/// `PlaybackTrack` and the download pipeline.
final class TrackPreferenceStore {
    /// A track as it looked when chosen. `id` alone can't safely restore it:
    /// track ids are physical container positions, not stable identifiers, so
    /// the same id can later belong to a different track after a re-mux,
    /// reordered streams, or a different version resolving — with no change in
    /// track count. `title` is the sanity check
    /// `PlayerViewModel.applyStoredTrackSelection()` matches on, skipping to the
    /// engine's default on a mismatch as it would for a missing id.
    struct TrackChoice: Codable, Equatable {
        var id: Int
        var title: String
    }

    /// One item's remembered choice. A `nil` `audioTrack` means audio was never
    /// picked, leaving the engine's default alone. `subtitlePreference` is a
    /// tri-state rather than a nested optional: "off" is as meaningful a
    /// remembered choice as any track, and distinct from nothing recorded.
    struct TrackSelection: Codable, Equatable {
        enum SubtitlePreference: Codable, Equatable {
            case unset
            case off
            case track(TrackChoice)
        }

        var audioTrack: TrackChoice?
        var subtitlePreference: SubtitlePreference = .unset
        /// When this entry was last written, not last applied: the recency
        /// signal eviction uses once `maxEntries` is exceeded.
        ///
        /// `Optional` rather than defaulted, because a synthesized `Decodable`
        /// ignores property defaults for missing keys and would fail outright on
        /// data written before this field existed, wiping every user's
        /// remembered tracks on upgrade. A `nil` sorts oldest and is evicted
        /// first, the conservative default for an undatable choice.
        var lastUpdated: Date?
    }

    /// A ceiling rather than a realistic limit: entries are a few dozen bytes
    /// each, so even a full store stays under a megabyte. It exists to guarantee
    /// a bound, not because the unbounded version caused trouble. Trims on write
    /// like `SearchHistoryStore`, but evicts by recency since these entries have
    /// no natural order.
    private static let defaultMaxEntries = 1000

    private let defaults: UserDefaults
    private let maxEntries: Int
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(defaults: UserDefaults = .standard, maxEntries: Int = TrackPreferenceStore.defaultMaxEntries) {
        self.defaults = defaults
        self.maxEntries = maxEntries
    }

    private func key(userID: String) -> String { "playback.trackPreference.\(userID)" }

    func selection(forItem itemID: String, userID: String) -> TrackSelection? {
        preferences(userID: userID)[itemID]
    }

    func recordAudioSelection(_ track: TrackChoice, forItem itemID: String, userID: String) {
        var prefs = preferences(userID: userID)
        var selection = prefs[itemID] ?? TrackSelection()
        selection.audioTrack = track
        selection.lastUpdated = Date()
        prefs[itemID] = selection
        save(trimmed(prefs), userID: userID)
    }

    /// `nil` records "off" as a deliberate choice, as it does for
    /// `PlaybackEngine.selectSubtitleTrack(id:)`.
    func recordSubtitleSelection(_ track: TrackChoice?, forItem itemID: String, userID: String) {
        var prefs = preferences(userID: userID)
        var selection = prefs[itemID] ?? TrackSelection()
        selection.subtitlePreference = track.map { .track($0) } ?? .off
        selection.lastUpdated = Date()
        prefs[itemID] = selection
        save(trimmed(prefs), userID: userID)
    }

    /// Evicts the least recently written entries once `prefs` exceeds
    /// `maxEntries`. A read — a re-watch that changes no track — doesn't refresh
    /// an entry's position. A `nil` `lastUpdated` sorts oldest and goes first.
    private func trimmed(_ prefs: [String: TrackSelection]) -> [String: TrackSelection] {
        guard prefs.count > maxEntries else { return prefs }
        let keep = prefs
            .sorted { ($0.value.lastUpdated ?? .distantPast) > ($1.value.lastUpdated ?? .distantPast) }
            .prefix(maxEntries)
        return Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
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
