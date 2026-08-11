import Foundation

/// One eligible dynamic Home rail, discovered from the server's actual
/// genre/studio/person data (`HomeViewModel.loadDynamicRailCandidates`) —
/// not yet fetched into a `MediaCollectionRail`. Kept as its own
/// lightweight, directly-testable type rather than inlined into
/// `HomeViewModel` since `railTitle`'s formatting logic is worth pinning
/// down with its own unit tests, independent of any networking.
///
/// An enum with associated values, not a struct with a `kind`/`category`
/// pair — `.genre`/`.studio` need a movie-vs-show split (Jellyfin's own
/// `/Genres`/`/Studios` are scoped by `IncludeItemTypes`), but `.actor`/
/// `.director` don't (`/Persons` has no such scoping, and there's no
/// product reason to split "Starring Tom Hanks" into a movies-only and a
/// shows-only rail) — a shared `kind` field would leave it meaningless on
/// two of the four cases.
enum DynamicRailCandidate: Hashable {
    /// `kind` is only ever `.movie` or `.series`.
    case genre(kind: BaseItemKind, name: String)
    /// Covers both movie studios and TV networks — Jellyfin has no
    /// separate "Network" concept, both are stored as `Studios`. The
    /// movie/show split shows up in `railTitle`'s wording, same as
    /// `.genre`. `kind` is only ever `.movie` or `.series`.
    case studio(kind: BaseItemKind, name: String)
    case actor(name: String)
    case director(name: String)

    /// e.g. "Action Movies" / "Documentary Shows" for genres, "Movies from
    /// Marvel Studios" / "Shows from HBO" for studios, "Starring Tom Hanks"
    /// for actors, "Directed by Christopher Nolan" for directors.
    var railTitle: String {
        switch self {
        case .genre(let kind, let name):
            return kind == .movie ? "\(name) Movies" : "\(name) Shows"
        case .studio(let kind, let name):
            return kind == .movie ? "Movies from \(name)" : "Shows from \(name)"
        case .actor(let name):
            return "Starring \(name)"
        case .director(let name):
            return "Directed by \(name)"
        }
    }

    /// This candidate's rail's "See All" link — the Movies/Shows grid,
    /// scoped to this candidate's `kind`, with the matching genre/studio
    /// filter preset (see `CollectionQuery`'s own doc comment on why a
    /// preset filter, not just a preset parent/type). `nil` for
    /// `.actor`/`.director`: those rails span both movies and shows at once
    /// (see this type's own doc comment on why they have no `kind`), which
    /// doesn't map onto a single-library `CollectionQuery` the way
    /// `.genre`/`.studio` (each pinned to one `kind`) do — and `Person`/
    /// `PersonTypes` isn't a `CollectionGridViewModel` filter facet at all,
    /// so there'd be nothing for a preset to seed even for a single
    /// library.
    ///
    /// - Parameters:
    ///   - moviesLibraryID/showsLibraryID: `HomeViewModel`'s own
    ///     already-resolved library IDs, passed in rather than looked up
    ///     here — this type has no `JellyfinAPIClient` of its own to look
    ///     them up with, same reasoning as `HomeViewModel.load()`'s curated
    ///     rails' own `seeAllQuery`s.
    func seeAllQuery(moviesLibraryID: String?, showsLibraryID: String?) -> CollectionQuery? {
        switch self {
        case .genre(let kind, let name):
            return CollectionQuery(
                title: kind == .movie ? String(localized: "Movies") : String(localized: "Shows"),
                parentID: kind == .movie ? moviesLibraryID : showsLibraryID,
                includeItemTypes: [kind.rawValue],
                initialGenre: name
            )
        case .studio(let kind, let name):
            return CollectionQuery(
                title: kind == .movie ? String(localized: "Movies") : String(localized: "Shows"),
                parentID: kind == .movie ? moviesLibraryID : showsLibraryID,
                includeItemTypes: [kind.rawValue],
                initialStudio: name
            )
        case .actor, .director:
            return nil
        }
    }
}
