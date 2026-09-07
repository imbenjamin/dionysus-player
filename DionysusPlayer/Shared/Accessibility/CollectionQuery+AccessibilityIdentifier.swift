import Foundation

/// App-side conveniences over `A11yID`, kept out of that file so it can be
/// compiled into the UI test target — which does not link the app module and
/// so cannot see `CollectionQuery`.

extension CollectionQuery {
    /// A stable, non-localized key for this query, for building an
    /// accessibility identifier out of. `title` is deliberately not part of
    /// it — that is generated, localized display text.
    var identifierKey: String {
        let scope = parentID ?? "all"
        let types = includeItemTypes.isEmpty ? "any" : includeItemTypes.sorted().joined(separator: "-")
        return "\(scope).\(types)"
    }
}

extension A11yID.Home {
    static func seeAll(_ query: CollectionQuery) -> String { seeAll(query.identifierKey) }
}
