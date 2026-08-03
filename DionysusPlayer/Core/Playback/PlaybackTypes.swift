import Foundation

/// Playback state as the rest of the app sees it — deliberately smaller
/// than AetherEngine's own state so feature code isn't coupled to it.
enum PlaybackState: Equatable {
    case idle
    case loading
    case playing
    case paused
    case seeking
    case ended
    case failed(String)
}

/// A selectable audio or subtitle track, normalized from whatever track
/// type the playback engine exposes.
struct PlaybackTrack: Identifiable, Hashable {
    enum Kind: Hashable {
        case audio
        case subtitle
    }

    var id: Int
    var kind: Kind
    var displayTitle: String
    var isSelected: Bool
}
