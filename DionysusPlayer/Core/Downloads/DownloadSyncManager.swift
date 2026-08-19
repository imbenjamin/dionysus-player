import Foundation

/// Pushes local offline watched/resume state back to the server once
/// reconnected. Wired into the **existing** reconnect-detection point —
/// `DionysusPlayerApp.swift`'s `.onChange(of: scenePhase)` block, which
/// already fires `client.healthCheck()` on every foreground transition —
/// gated on `!ConnectivityMonitor.shared.isOffline`. No `BGTaskScheduler`;
/// see the offline-downloads plan's "Sync manager" section.
@MainActor
enum DownloadSyncManager {
    /// Queries `store` for `pendingSync` rows, calls `updateUserData(...)`
    /// per row, and on success either flips `pendingSync = false` (the row
    /// still has files, the user is still "using" the download) or, if
    /// `markedForDeletion == true`, deletes the row outright — its only
    /// remaining purpose was carrying this sync payload, and that payload
    /// has now landed. A failure just leaves the row as-is for the next
    /// trigger either way — no retry backoff of its own, since the next
    /// reconnect (or app foreground) calls this again regardless.
    static func syncIfNeeded(client: JellyfinAPIClient, store: DownloadStore) async {
        for item in store.pendingSyncItems() {
            do {
                try await client.updateUserData(
                    itemID: item.itemID, userID: item.userID,
                    positionTicks: item.resumePositionTicks, isPlayed: item.isPlayed, playedPercentage: item.playedPercentage,
                    // The real, on-device offline-watch moment, not now —
                    // see `DownloadedItem.lastPlayedAt`'s doc comment.
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
