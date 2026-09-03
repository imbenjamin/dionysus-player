import Foundation

/// Identifies a full-screen playback presentation (`.fullScreenCover(item:)`).
struct PlaybackRequest: Identifiable, Hashable {
    var itemID: String
    /// When true, ignore the item's saved resume position and start from 0
    /// (drives the "Restart" button on the asset detail pages).
    var startFromBeginning: Bool = false
    /// The specific `mediaSources` entry to play (see `MediaItem
    /// .mediaVersions`) — set by `PlayResumeButtonRow`'s version-choice
    /// prompt for a fresh Play/Restart, or looked up from
    /// `AssetDetailViewModel.preferredMediaSourceID(forPlayableItem:)` for a
    /// Resume. `nil` for a single/no-version item, letting `PlayerViewModel`
    /// fall back to the server's own default source.
    var mediaSourceID: String?
    /// An explicit position to start playback at, overriding both
    /// `startFromBeginning` and the item's saved resume position — set only
    /// by a Chapters rail tap (`ChapterRailView`). `nil` for every ordinary
    /// Play/Resume/Restart, leaving the existing behavior untouched. See
    /// `PlayerView.startSeconds` for how it reaches `PlayerViewModel`.
    var startSeconds: TimeInterval?
    /// Include every field in the identity so a different action right after
    /// another (e.g. Restart tapped right after a Resume, picking a
    /// different version on a second Play, or tapping a *second* chapter
    /// straight after a first) presents a fresh sheet rather than being
    /// coalesced as "same itemID, no change".
    var id: String {
        // Split out rather than interpolated inline — an inline
        // `startSeconds.map(String.init)` inside the same interpolation is
        // ambiguous enough to blow up Swift's type checker outright
        // ("failed to produce diagnostic for expression"), not just slow it
        // down.
        let start = startSeconds.map { String($0) } ?? ""
        return "\(itemID)-\(startFromBeginning)-\(mediaSourceID ?? "")-\(start)"
    }
}
