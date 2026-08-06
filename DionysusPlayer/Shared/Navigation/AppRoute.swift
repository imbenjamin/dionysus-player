import Foundation

/// Push destinations shared by every tab's `NavigationStack`.
enum AppRoute: Hashable {
    case collection(CollectionQuery)
    /// `preloadedItem` is whatever `MediaItem` the pushing card already had
    /// in hand (a poster/hero card always does) — `AssetDetailView` renders
    /// it immediately instead of a spinner while it fetches the rest (cast,
    /// technical details, similar/collections rails) in the background.
    case assetDetail(itemID: String, preloadedItem: MediaItem? = nil)
}
