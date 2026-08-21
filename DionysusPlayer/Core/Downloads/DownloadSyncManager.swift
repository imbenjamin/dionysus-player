import Foundation

/// Pushes local offline watched/resume state back to the server once
/// reconnected. Wired into the **existing** reconnect-detection point —
/// `DionysusPlayerApp.swift`'s `.onChange(of: scenePhase)` block, which
/// already fires `client.healthCheck()` on every foreground transition —
/// gated on `!ConnectivityMonitor.shared.isOffline`. No `BGTaskScheduler`;
/// see the offline-downloads plan's "Sync manager" section.
@MainActor
enum DownloadSyncManager {
    /// Guards against overlapping passes — every scenePhase-driven
    /// foreground transition in `DionysusPlayerApp` spawns its own
    /// untracked call to `syncIfNeeded` below, with nothing coordinating
    /// between separate calls. A real inefficiency, found in a 2026-08-20
    /// branch review: rapid foreground/background cycling (switching to
    /// Messages and back, Control Center — both routine) fires overlapping
    /// passes, each re-reading `store.pendingSyncItems()` before an
    /// earlier pass has had a chance to flip `pendingSync = false` for the
    /// same rows, so the same `updateUserData` POST could go out
    /// redundantly more than once for one watched/resume update. A second
    /// call arriving while one's already running is now a no-op — the
    /// in-flight pass already covers whatever was pending when it started,
    /// and anything that becomes pending *during* that pass gets picked up
    /// by the next trigger regardless, same "no retry backoff of its own"
    /// reasoning `syncIfNeeded`'s own doc comment below already gives for
    /// a failed row.
    private static var isSyncing = false

    /// Queries `store` for `pendingSync` rows, calls `updateUserData(...)`
    /// per row, and on success either flips `pendingSync = false` (the row
    /// still has files, the user is still "using" the download) or, if
    /// `markedForDeletion == true`, deletes the row outright — its only
    /// remaining purpose was carrying this sync payload, and that payload
    /// has now landed. A failure just leaves the row as-is for the next
    /// trigger either way — no retry backoff of its own, since the next
    /// reconnect (or app foreground) calls this again regardless.
    static func syncIfNeeded(client: JellyfinAPIClient, store: DownloadStore) async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
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
