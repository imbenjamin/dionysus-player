import Foundation

/// Remembers the audio/subtitle tracks a user explicitly picked for an item
/// during a previous playback session, so returning to it later restores
/// those choices instead of falling through the engine's own default/
/// forced-subtitle selection every time — see `PlayerViewModel
/// .applyStoredTrackSelection()`'s doc comment for how this interacts with
/// `AetherPlaybackEngine`'s forced-subtitle auto-select.
///
/// Local to the device only, like `MediaVersionPreferenceStore`: plain
/// `UserDefaults`, not sensitive, never round-tripped through the server —
/// investigated and deliberately rejected using Jellyfin's own server-side
/// equivalent (`UserItemData.AudioStreamIndex`/`SubtitleStreamIndex`) for
/// this instead: its `MediaSourceInfo.DefaultAudioStreamIndex`/
/// `DefaultSubtitleStreamIndex` fields are always populated by a
/// language-preference/forced-subtitle fallback even when the user never
/// made a real choice, and the one field that would tell a client which
/// case it's looking at (`AudioIndexSource`) is `[JsonIgnore]`d server-side
/// and never sent over the API at all (no subtitle equivalent exists even
/// internally) — a client can't trust it without doing the same local
/// validation this store already does, at which point the round-trip adds
/// cost without adding safety. Scoped per user for the same shared-device
/// reasoning as the sibling stores.
///
/// Keyed by item id alone (not media source, not "live" vs. "downloaded")
/// — same scoping as `MediaVersionPreferenceStore`, and it's *the same
/// item* either way, so this store makes no distinction between a choice
/// made while streaming live and one made while playing a downloaded copy;
/// `PlayerViewModel.start()`/`.startOffline()` both read and write through
/// the exact same entry (see `test_selection_isSharedAcrossPlaybackContexts`
/// below — do not add a `mediaSourceID`/context parameter to this store's
/// API, which would fragment that further).
///
/// That sharing does **not**, in practice, mean a subtitle choice reliably
/// restores across the live/downloaded boundary — investigated live
/// 2026-08-31 (Office Space) and dropped as not worth pursuing further: a
/// download always transcodes to a different, more limited media source
/// than the live one (down to a single baked-in audio track;
/// `DownloadedItem.selectedAudioTrackIndex`), and a downloaded subtitle
/// track's title (`DownloadedSubtitleFile.displayTitle`, sourced from
/// Jellyfin's server-computed `MediaStream.displayTitle`) frequently
/// doesn't match the same track's title as seen live (an *embedded*
/// subtitle's title there comes from AetherEngine's own container
/// metadata, with no Jellyfin field involved at all — and even for an
/// *external* one, `MediaStream.title`, the field live playback uses,
/// turned out to disagree with `.displayTitle` often enough that swapping
/// to it didn't fix the repro either). `PlayerViewModel
/// .applyStoredTrackSelection()`'s exact id+title match (deliberately
/// strict — see its own doc comment) just quietly declines to restore
/// when this happens, same as any other stale/mismatched entry — not a
/// crash or a corrupted choice, just an unfulfilled nice-to-have. Fixing
/// it for real would mean plumbing a title-independent identity (language
/// code, most likely) through both `PlaybackTrack` and the download
/// pipeline — out of scope unless this becomes worth revisiting.
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
        /// When this entry was last written to (not last read/applied at
        /// playback) — the recency signal `trimIfNeeded` evicts by once
        /// `maxEntries` is exceeded. `Optional` rather than defaulted to
        /// `Date()` so decoding data written before this field existed
        /// doesn't fail outright (a `Decodable` synthesized initializer
        /// ignores property defaults for missing keys — only `Optional`
        /// properties tolerate an absent key) and silently wipe every
        /// existing user's remembered tracks on upgrade. A `nil` sorts as
        /// the oldest possible entry — first to be evicted — which is the
        /// right conservative default for a choice this store can't date.
        var lastUpdated: Date?
    }

    /// A real ceiling, not a realistic one: a personal Jellyfin library
    /// touched by track selection this many times over would be enormous.
    /// Each entry is a few dozen bytes, so even a full store stays well
    /// under a megabyte — this exists to guarantee a bound at all, not
    /// because the unbounded version was observed to be a practical
    /// problem. Mirrors `SearchHistoryStore.maxEntries`'s trim-on-write
    /// shape, just evicting by recency-of-write rather than always
    /// trimming to the tail of an ordered list, since entries here aren't
    /// naturally ordered the way a linear search history is.
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

    /// `nil` records "off" as a deliberate choice, same as
    /// `PlaybackEngine.selectSubtitleTrack(id:)`'s own `nil` meaning.
    func recordSubtitleSelection(_ track: TrackChoice?, forItem itemID: String, userID: String) {
        var prefs = preferences(userID: userID)
        var selection = prefs[itemID] ?? TrackSelection()
        selection.subtitlePreference = track.map { .track($0) } ?? .off
        selection.lastUpdated = Date()
        prefs[itemID] = selection
        save(trimmed(prefs), userID: userID)
    }

    /// Evicts the least-recently-*written* entries once `prefs` exceeds
    /// `maxEntries` — a read (a plain re-watch that never changes the
    /// stored track) doesn't refresh an entry's position, same as
    /// `SearchHistoryStore`'s history only reordering on `record`, not on
    /// `history(userID:)` reads. `nil` (pre-cap data written before
    /// `lastUpdated` existed) sorts oldest, so it's evicted first.
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
