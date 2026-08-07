import Foundation

/// Which field `CollectionGridView`'s grid is ordered by, exposed via a
/// toolbar menu — independent of whatever `CollectionQuery` describes
/// (that's just parent/type filtering). Paired with a separate
/// `CollectionSortOrder` (ascending/descending), which applies uniformly
/// across all three fields — none of them has a "locked" direction.
/// Defaults to `.title`.
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

/// Ascending/descending, independently selectable for any
/// `CollectionSortField` — e.g. "A→Z" (ascending) or "Z→A" (descending)
/// when sorting by title, oldest-first or newest-first for the date-based
/// fields. Defaults to `.ascending`.
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
