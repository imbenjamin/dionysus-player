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
    /// Include both flags in the identity so a different action right after
    /// another (e.g. Restart tapped right after a Resume, or picking a
    /// different version on a second Play) presents a fresh sheet rather
    /// than being coalesced as "same itemID, no change".
    var id: String { "\(itemID)-\(startFromBeginning)-\(mediaSourceID ?? "")" }
}
