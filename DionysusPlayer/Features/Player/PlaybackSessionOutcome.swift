import Foundation

/// What `PlayerView.close()` reports back to whichever screen presented it —
/// its own final position, known with certainty the moment playback stops,
/// rather than something the presenter has to wait to learn back from the
/// server.
///
/// `AssetDetailViewModel.refreshItem()` already re-fetches the played item
/// after the player closes, but Jellyfin's write endpoints return before the
/// userData change is actually committed and queryable — confirmed live
/// (2026-08-13) that even a generous ~13s poll window isn't reliably enough:
/// resuming a movie, scrubbing to a different position, and exiting within a
/// few seconds left the detail page's progress bar stuck on the pre-scrub
/// position well past that window, even though the write itself had landed
/// correctly (confirmed by Resume picking up the right spot). Rather than
/// keep extending an already-generous timeout and hoping, `PlayerView`
/// reports this outcome directly so the presenter can reflect it
/// immediately — see `AssetDetailViewModel.applyOptimisticPlaybackPosition(_:)`.
/// `refreshItem()` still runs afterward to reconcile with the server's own
/// authoritative values, in particular `played` (see that method's own doc
/// comment for why this type deliberately doesn't try to guess that part).
struct PlaybackSessionOutcome {
    /// The item that was actually playing — matches `PlayerView.itemID`,
    /// which is what the presenter needs to know *which* of its own
    /// properties (`AssetDetailViewModel.item`/`.showPlaybackEpisode`) this
    /// outcome belongs to.
    let itemID: String
    let positionSeconds: TimeInterval
    let durationSeconds: TimeInterval
}
