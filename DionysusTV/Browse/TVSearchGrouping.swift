import Foundation

/// Search results as rails by type, in a fixed order, each keeping the
/// server's own order. Nothing is dropped: a kind without a rail of its own
/// goes under Other.
enum TVSearchGrouping {
    struct Section: Equatable, Identifiable {
        let id: String
        let title: String
        let results: [SearchResult]
    }

    private static let order: [(id: String, kinds: Set<BaseItemKind>, title: @Sendable () -> String)] = [
        ("movies", [.movie], { String(localized: "Movies") }),
        ("shows", [.series], { String(localized: "Shows") }),
        ("episodes", [.episode], { String(localized: "Episodes") }),
        ("collections", [.boxSet], { String(localized: "Collections") }),
        ("playlists", [.playlist], { String(localized: "Playlists") })
    ]

    static func sections(_ results: [SearchResult]) -> [Section] {
        var sections = order.compactMap { entry -> Section? in
            let matching = results.filter { result in result.kind.map(entry.kinds.contains) ?? false }
            return matching.isEmpty ? nil : Section(id: entry.id, title: entry.title(), results: matching)
        }
        let known = order.reduce(into: Set<BaseItemKind>()) { $0.formUnion($1.kinds) }
        let other = results.filter { result in !(result.kind.map(known.contains) ?? false) }
        if !other.isEmpty {
            sections.append(Section(id: "other", title: String(localized: "Other"), results: other))
        }
        return sections
    }
}
