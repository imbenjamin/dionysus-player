import Foundation

/// One eligible (content type, category, name) combination for a dynamic
/// Home rail, discovered from the server's actual genre/studio lists
/// (`HomeViewModel.loadDynamicRailCandidates`) — not yet fetched into a
/// `MediaCollectionRail`. Kept as its own lightweight, directly-testable
/// type rather than inlined into `HomeViewModel` since `railTitle`'s
/// formatting logic is worth pinning down with its own unit tests,
/// independent of any networking.
struct DynamicRailCandidate: Hashable {
    enum Category {
        case genre
        /// Covers both movie studios and TV networks — Jellyfin has no
        /// separate "Network" concept, both are stored as `Studios`. The
        /// movie/show split shows up in `railTitle`'s wording, not here.
        case studio
    }

    /// Only `.movie` and `.series` are ever constructed — every other
    /// `BaseItemKind` case is meaningless for a dynamic rail.
    var kind: BaseItemKind
    var category: Category
    var name: String

    /// e.g. "Action Movies" / "Documentary Shows" for genres,
    /// "Movies from Marvel Studios" / "Shows from HBO" for studios.
    var railTitle: String {
        switch category {
        case .genre:
            return kind == .movie ? "\(name) Movies" : "\(name) Shows"
        case .studio:
            return kind == .movie ? "Movies from \(name)" : "Shows from \(name)"
        }
    }
}
