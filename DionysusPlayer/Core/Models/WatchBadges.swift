import Foundation

/// Which corner badges a tile shows, on iOS and the Apple TV alike: a heart
/// for a favourite, an eye for a played item, and a progress bar while there
/// is something to resume. All three can show together: a rewatch stopped
/// partway keeps `Played` and stores a new position (Benjamin, 2026-11-01), as
/// `MediaItem.canResume` also allows.
struct WatchBadges: Equatable {
    let showsFavorite: Bool
    let showsWatched: Bool
    /// The played fraction, `nil` unless the item is part-watched or a rewatch
    /// stopped partway.
    let progress: Double?

    /// `hasResumePosition` is what tells a rewatch from a finished item, which
    /// can report a fraction (100%) too, or from a fully watched show, which
    /// has no position of its own.
    init(isFavorite: Bool, isPlayed: Bool, playedFraction: Double?, hasResumePosition: Bool = false) {
        showsFavorite = isFavorite
        showsWatched = isPlayed
        if let playedFraction, playedFraction > 0, !isPlayed || hasResumePosition {
            progress = playedFraction
        } else {
            progress = nil
        }
    }

    init(item: MediaItem) {
        self.init(
            isFavorite: item.isFavorite,
            isPlayed: item.isPlayed,
            playedFraction: item.playedFraction,
            hasResumePosition: item.dto.type != .series && item.dto.type != .season
                && (item.resumePositionSeconds ?? 0) > 0
        )
    }
}
