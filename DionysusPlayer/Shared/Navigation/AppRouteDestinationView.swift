import SwiftUI

/// Maps an `AppRoute` to its destination view. Registered once per tab's
/// `NavigationStack` via `.navigationDestination(for: AppRoute.self)`.
struct AppRouteDestinationView: View {
    let route: AppRoute

    /// Read here, synchronously, so `AssetDetailView` can build its
    /// `viewModel` in `init` rather than lazily via `.task` — avoids a
    /// render pass showing a blank `LoadingView()` before that `.task` gets
    /// a chance to run, which is otherwise unavoidable even with a
    /// `preloadedItem` on hand (see `AssetDetailView`'s doc comment).
    @Environment(AppState.self) private var appState

    var body: some View {
        switch route {
        case .collection(let query):
            CollectionGridView(query: query)
        case .assetDetail(let itemID, let preloadedItem):
            // `currentUser?.id` alone isn't enough: a cold launch that
            // resumed `.main` from a cached session (see `AppState.start()`)
            // never gets a fresh `UserDto` until a real sign-in eventually
            // succeeds, so this falls back to the cached `userID` from that
            // prior sign-in — same idiom `PlayerView` uses for offline
            // playback.
            if let client = appState.apiClient,
               let userID = appState.currentUser?.id ?? appState.sessionStore.credentials?.userID {
                AssetDetailView(itemID: itemID, preloadedItem: preloadedItem, client: client, userID: userID)
            } else {
                // This router only ever renders once signed in at least
                // once (`.main` phase), so this shouldn't happen in
                // practice — but avoid a hard crash if it somehow does.
                ErrorStateView(message: String(localized: "You're not signed in."), retry: nil)
            }
        // The three offline-downloads routes below need no live session at
        // all (unlike `.assetDetail` above) — reachable from `MainTabView`'s
        // Downloads tab regardless of connectivity or sign-in state.
        case .downloadedAsset(let itemID):
            DownloadedAssetDetailView(itemID: itemID, downloadManager: appState.downloadManager, client: appState.apiClient)
        case .downloadedShow(let seriesID):
            DownloadedShowView(seriesID: seriesID, downloadManager: appState.downloadManager)
        case .downloadedSeason(let seriesID, let seasonID):
            DownloadedSeasonView(seriesID: seriesID, seasonID: seasonID, downloadManager: appState.downloadManager)
        }
    }
}
