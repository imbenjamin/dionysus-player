import Foundation

/// Identifies a full-screen playback presentation (`.fullScreenCover(item:)`).
struct PlaybackRequest: Identifiable, Hashable {
    var itemID: String
    var id: String { itemID }
}
