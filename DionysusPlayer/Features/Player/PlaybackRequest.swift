import Foundation

/// Identifies a full-screen playback presentation (`.fullScreenCover(item:)`).
struct PlaybackRequest: Identifiable, Hashable {
    var itemID: String
    /// When true, ignore the item's saved resume position and start from 0
    /// (drives the "Restart" button on the asset detail pages).
    var startFromBeginning: Bool = false
    /// Include the flag in the identity so a Restart tapped right after a
    /// Resume presents a fresh sheet rather than being coalesced as "same
    /// itemID, no change".
    var id: String { "\(itemID)-\(startFromBeginning)" }
}
