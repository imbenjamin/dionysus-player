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
}
