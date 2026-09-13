import Foundation

/// Which field `CollectionGridView`'s grid is ordered by, from its toolbar menu.
/// Independent of `CollectionQuery`, which only filters by parent and type.
/// Paired with `CollectionSortOrder`, which applies uniformly — no field has a
/// locked direction.
enum CollectionSortField: CaseIterable, Identifiable, Hashable {
    case title
    case dateAdded
    case releaseDate

    var id: Self { self }

    /// Jellyfin's `SortBy` query value.
    var sortBy: String {
        switch self {
        case .title: "SortName"
        case .dateAdded: "DateCreated"
        case .releaseDate: "PremiereDate"
        }
    }
}

/// Ascending or descending, selectable for any `CollectionSortField`: A→Z or Z→A
/// by title, oldest- or newest-first for the date fields.
enum CollectionSortOrder: CaseIterable, Identifiable, Hashable {
    case ascending
    case descending

    var id: Self { self }

    /// Jellyfin's `SortOrder` query value.
    var value: String {
        switch self {
        case .ascending: "Ascending"
        case .descending: "Descending"
        }
    }
}

/// `CollectionGridView`'s Watched facet, shaped like the genre, studio and
/// decade facets: an `Optional` selection where `nil` means no filter. An enum
/// rather than a `Bool?` so the filter pill has self-describing display values.
enum CollectionWatchStatus: CaseIterable, Identifiable, Hashable {
    case watched
    case unwatched

    var id: Self { self }
}

/// `CollectionGridView`'s Favorites facet, shaped like `CollectionWatchStatus`.
/// A three-way All/Favorites/Non-Favorites choice rather than an on/off toggle,
/// so favorites can be filtered out as well as down to.
enum CollectionFavoriteStatus: CaseIterable, Identifiable, Hashable {
    case favorite
    case nonFavorite

    var id: Self { self }
}
