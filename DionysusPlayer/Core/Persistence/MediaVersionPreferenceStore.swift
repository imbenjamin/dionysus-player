import Foundation

/// Remembers which `mediaSources` entry (see `MediaItem.mediaVersions`) last
/// played by choice: the answer to the "Choose a Version" question
/// (`versionedPlayback(_:anchor:viewModel:play:)`), or the version
/// auto-advance carried on to the next item. A later "Resume" then continues
/// that same version without asking, and the question marks it
/// "(Last Played)" (`MediaVersionResolver`).
///
/// This has to live client-side: Jellyfin's own resume position
/// (`UserItemDataDto.playbackPositionTicks`) is tracked per user+item, not
/// per media source, so the server has no notion of "which version were they
/// watching" to hand back on its own — see `MediaVersionChoice` for the
/// rule this supports.
///
/// Local to the device only: plain `UserDefaults`, like `SearchHistoryStore`
/// (not sensitive, never round-tripped through the server). Scoped per user,
/// same reasoning as `SearchHistoryStore` — a shared device switching
/// accounts shouldn't leak one user's version choice as another's.
final class MediaVersionPreferenceStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(userID: String) -> String { "playback.versionPreference.\(userID)" }

    func preferredMediaSourceID(forItem itemID: String, userID: String) -> String? {
        preferences(userID: userID)[itemID]
    }

    func setPreferredMediaSourceID(_ mediaSourceID: String, forItem itemID: String, userID: String) {
        var prefs = preferences(userID: userID)
        prefs[itemID] = mediaSourceID
        defaults.set(prefs, forKey: key(userID: userID))
    }

    private func preferences(userID: String) -> [String: String] {
        defaults.dictionary(forKey: key(userID: userID)) as? [String: String] ?? [:]
    }
}
