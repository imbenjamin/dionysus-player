import Foundation

/// A scoped query for the Collection grid screen — e.g. "all Movies",
/// "everything in this BoxSet", or a saved search. Sort/Genre/Studio are
/// still independently user-changeable from within the grid itself
/// (`CollectionGridViewModel.setSortField`/`setGenreFilter`/etc.) — the
/// `initial*` fields below only seed their *starting* value, for a "See
/// All" link that wants to land somewhere more specific than the grid's
/// own bare defaults (Title/ascending, no filter). e.g. a "Recently Added
/// Movies" rail's See All opens already sorted newest-first, and a dynamic
/// "Action Movies" rail's See All opens already filtered to Genre: Action
/// — in both cases so the destination matches what got the user there,
/// without them having to reapply it by hand.
struct CollectionQuery: Hashable {
    var title: String
    var parentID: String?
    var includeItemTypes: [String] = []
    var initialSortField: CollectionSortField = .title
    var initialSortOrder: CollectionSortOrder = .ascending
    var initialGenre: String? = nil
    var initialStudio: String? = nil
}
