import Foundation

/// Pushes local offline watched and resume state back to the server once
/// reconnected, from `DionysusPlayerApp`'s existing scenePhase handler — which
/// already fires `healthCheck()` on every foreground transition — gated on
/// `!ConnectivityMonitor.shared.isOffline`. No `BGTaskScheduler`.
@MainActor
enum DownloadSyncManager {
    /// Guards against overlapping passes. Each foreground transition spawns its
    /// own untracked `syncIfNeeded` call, so rapid cycling would fire passes
    /// that each re-read `store.pendingSyncItems()` before an earlier one clears
    /// them, sending the same POST repeatedly. A call arriving mid-pass is a
    /// no-op: the in-flight pass covers what was pending when it started, and
    /// anything newer is picked up by the next trigger.
    private static var isSyncing = false

    /// Calls `updateUserData(...)` for each `pendingSync` row. On success either
    /// clears `pendingSync`, or deletes a `markedForDeletion` row outright,
    /// since carrying this payload was its only remaining purpose. A failure
    /// leaves the row for the next trigger; no backoff of its own, since the
    /// next foreground transition calls this again.
    static func syncIfNeeded(client: JellyfinAPIClient, store: DownloadStore) async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        for item in store.pendingSyncItems() {
            do {
                try await client.updateUserData(
                    itemID: item.itemID, userID: item.userID,
                    positionTicks: item.resumePositionTicks, isPlayed: item.isPlayed, playedPercentage: item.playedPercentage,
                    // The on-device offline-watch moment, not now.
                    lastPlayedDate: item.lastPlayedAt
                )
                if item.markedForDeletion {
                    store.delete(item)
                } else {
                    item.pendingSync = false
                    item.lastSyncedAt = Date()
                    store.save()
                }
            } catch {
                continue
            }
        }
    }
}
