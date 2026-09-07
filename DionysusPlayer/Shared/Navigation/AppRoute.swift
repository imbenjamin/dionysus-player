import Foundation

/// Push destinations shared by every tab's `NavigationStack`.
enum AppRoute: Hashable {
    case collection(CollectionQuery)
    /// `preloadedItem` is whatever `MediaItem` the pushing card already had
    /// in hand (a poster/hero card always does) — `AssetDetailView` renders
    /// it immediately instead of a spinner while it fetches the rest (cast,
    /// technical details, similar/collections rails) in the background.
    case assetDetail(itemID: String, preloadedItem: MediaItem? = nil)
    /// An offline-downloaded item's own detail page
    /// (`DownloadedAssetDetailView`) — distinct from `.assetDetail`, which
    /// assumes a live, network-backed `BaseItemDto`.
    case downloadedAsset(itemID: String)
    /// A show's downloaded episodes, grouped by season only if more than
    /// one season is actually downloaded (`DownloadedShowView`'s own doc
    /// comment).
    case downloadedShow(seriesID: String)
    /// One season's downloaded episodes (`DownloadedSeasonView`) — only
    /// ever pushed from `.downloadedShow` when it found more than one
    /// season present.
    case downloadedSeason(seriesID: String, seasonID: String)
}
