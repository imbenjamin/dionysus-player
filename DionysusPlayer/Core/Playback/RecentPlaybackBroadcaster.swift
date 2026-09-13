import Observation

/// Broadcasts the most recent `PlaybackSessionOutcome`, posted by
/// `PlayerView.tearDown()` for every session whatever screen presented it, so
/// any feature showing a resume position can reflect it without waiting on
/// Jellyfin's userData commit latency.
///
/// The same problem `AssetDetailViewModel.applyOptimisticPlaybackPosition(_:)`
/// solves for the detail page, broadcast globally rather than handed to one
/// presenter. `HomeViewModel`'s Continue Watching and Next Up rails are the only
/// other consumer: their soft refresh was a single unguarded server fetch with
/// no optimistic overlay, so a resume point looked accurate on the detail page
/// and stale on Home moments later.
///
/// A plain singleton, referenced directly from view-model code rather than
/// through `Environment`.
@MainActor
@Observable
final class RecentPlaybackBroadcaster {
    static let shared = RecentPlaybackBroadcaster()

    private var pendingOutcome: PlaybackSessionOutcome?

    private init() {}

    func record(_ outcome: PlaybackSessionOutcome) {
        pendingOutcome = outcome
    }

    /// Single-shot: returns the pending outcome and clears it, so each is
    /// consumed once. Fine with one consumer; a second would need its own
    /// delivery rather than racing this one for the same value.
    func consume() -> PlaybackSessionOutcome? {
        defer { pendingOutcome = nil }
        return pendingOutcome
    }

    /// Test-only reset.
    func reset() {
        pendingOutcome = nil
    }
}
