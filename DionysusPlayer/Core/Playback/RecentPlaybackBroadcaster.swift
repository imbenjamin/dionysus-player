import Observation

/// Broadcasts the most recent `PlaybackSessionOutcome` — posted centrally by
/// `PlayerView.tearDown()` for every playback session, regardless of which
/// screen presented it — so any other feature that shows a resume/progress
/// position can reflect it immediately rather than waiting on Jellyfin's own
/// userData commit latency to catch up. This is the same problem
/// `AssetDetailViewModel.applyOptimisticPlaybackPosition(_:)` already solves
/// for the detail page itself (see that method's own doc comment for the
/// underlying server behavior), just broadcast globally instead of handed
/// directly to one presenter — `HomeViewModel`'s Continue Watching/Next Up
/// rails are today's only other consumer, added after a resume point was
/// confirmed live (2026-09-02) to look accurate on the detail page right
/// after playback but stale on Home moments later: Home's soft refresh was
/// doing a single unguarded server fetch with no optimistic overlay at all,
/// unlike the detail page.
///
/// Follows the same plain-singleton convention as `ConnectivityMonitor
/// .shared`/`LibraryAvailability.shared` — referenced directly in view
/// model code rather than routed through SwiftUI's `Environment`.
@MainActor
@Observable
final class RecentPlaybackBroadcaster {
    static let shared = RecentPlaybackBroadcaster()

    private var pendingOutcome: PlaybackSessionOutcome?

    private init() {}

    func record(_ outcome: PlaybackSessionOutcome) {
        pendingOutcome = outcome
    }

    /// Single-shot: returns the pending outcome (if any) and clears it, so
    /// each posted outcome is only ever consumed once. Fine with exactly
    /// one consumer today (`HomeViewModel`); a second consumer would need
    /// its own delivery mechanism rather than racing this one for the same
    /// single value.
    func consume() -> PlaybackSessionOutcome? {
        defer { pendingOutcome = nil }
        return pendingOutcome
    }

    /// Test-only reset — mirrors `LibraryAvailability.reset()`.
    func reset() {
        pendingOutcome = nil
    }
}
