import Foundation

/// A titled row of items on the Home screen (e.g. "Continue Watching",
/// "Recently Added Movies").
///
/// Rail *selection* — which collections/queries actually populate the home
/// screen — is deliberately minimal for now; the set of rails is expected
/// to be redefined later.
struct MediaCollectionRail: Identifiable {
    var id: String { title }
    var title: String
    var items: [MediaItem]
    /// When set, the rail shows a "See All" link pushing a `CollectionGridView`
    /// scoped to this query.
    var seeAllQuery: CollectionQuery? = nil
}
