import Foundation

/// A scoped query for the Collection grid screen — e.g. "all Movies",
/// "everything in this BoxSet", or a saved search.
struct CollectionQuery: Hashable {
    var title: String
    var parentID: String?
    var includeItemTypes: [String] = []
    var sortBy: String = "SortName"
    var sortOrder: String = "Ascending"
}
