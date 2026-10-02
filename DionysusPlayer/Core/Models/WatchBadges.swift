import Foundation

/// Which corner badges a tile shows, on iOS and the Apple TV alike: a heart
/// for a favourite, an eye for a played item, and a progress bar only while
/// the item is part-watched. The heart and the eye can show together.
struct WatchBadges: Equatable {
    let showsFavorite: Bool
    let showsWatched: Bool
    /// The played fraction, `nil` unless the item is part-watched.
    let progress: Double?

    init(isFavorite: Bool, isPlayed: Bool, playedFraction: Double?) {
        showsFavorite = isFavorite
        showsWatched = isPlayed
        if let playedFraction, playedFraction > 0, !isPlayed {
            progress = playedFraction
        } else {
            progress = nil
        }
    }

    init(item: MediaItem) {
        self.init(isFavorite: item.isFavorite, isPlayed: item.isPlayed, playedFraction: item.playedFraction)
    }
}
