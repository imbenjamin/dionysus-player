import Foundation

/// A scoped query for the Collection grid screen — e.g. "all Movies",
/// "everything in this BoxSet", or a saved search. Ordering isn't part of
/// this: `CollectionGridViewModel` owns that independently via
/// `CollectionSortOption`, since it's something the user changes from
/// within the grid itself, not something baked in by whoever navigated
/// here.
struct CollectionQuery: Hashable {
    var title: String
    var parentID: String?
    var includeItemTypes: [String] = []
}
