import Foundation

/// What `PlayerView.close()` reports back to whichever screen presented it —
/// its own final position, known with certainty the moment playback stops,
/// rather than something the presenter has to wait to learn back from the
/// server.
///
/// `AssetDetailViewModel.refreshItem()` already re-fetches the played item
/// after the player closes, but Jellyfin's write endpoints return before the
/// userData change is actually committed and queryable, so there's always
/// *some* server round-trip latency between closing the player and the
/// detail page's own fetch reflecting it — up to `refreshItem()`'s full
/// ~13s poll window in the worst case. (An earlier investigation, 2026-08-13,
/// also saw the progress bar stuck well past that window with no fix here
/// yet applied — but that specific symptom turned out to be a *separate*,
/// since-fixed bug, `MovieDetailView`/`ShowDetailView` not re-rendering at
/// all after their own `.fullScreenCover` dismissed — see
/// `[[fullscreencover-observable-not-rerendering]]`/`refreshTrigger` on
/// those views. That bug being real doesn't make this one imaginary,
/// though: even with rendering fixed, a multi-second wait to see your own
/// scrub reflected is bad UX on its own merits.) Rather than have the user
/// stare at stale data while polling catches up, `PlayerView` reports this
/// outcome directly so the presenter can reflect it immediately — see
/// `AssetDetailViewModel.applyOptimisticPlaybackPosition(_:)`. `refreshItem()`
/// still runs afterward to reconcile with the server's own authoritative
/// values, in particular `played` (see that method's own doc comment for
/// why this type deliberately doesn't try to guess that part).
struct PlaybackSessionOutcome {
    /// The item that was actually playing — matches `PlayerView.itemID`,
    /// which is what the presenter needs to know *which* of its own
    /// properties (`AssetDetailViewModel.item`/`.showPlaybackEpisode`) this
    /// outcome belongs to.
    let itemID: String
    let positionSeconds: TimeInterval
    let durationSeconds: TimeInterval
}
