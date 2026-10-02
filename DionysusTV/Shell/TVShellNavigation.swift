import Foundation

/// One pushed page. The id tells two visits to the same route apart, and
/// keys the page's view model and remembered focus in the shell.
struct TVPathEntry: Identifiable, Equatable {
    let id: UUID
    let route: AppRoute
}

/// Where the signed-in shell is (Benjamin, 2026-10-01). Every sidebar row but
/// the Libraries group is a top-level destination: Profile, Home, Search and
/// each library. The rail is drawn on all of them, and focus entering it lands
/// on the destination's own row, never on whichever row happened to be nearest.
struct TVShellNavigation: Equatable {
    typealias Row = TVSidebarLayout.Row

    enum Selection: Equatable {
        case navigated
        /// The Libraries row isn't a page: it opens and closes in place.
        case toggledGroup
    }

    /// Never `.librariesGroup`.
    private(set) var destination: Row = .home
    /// Pages pushed on top of the destination: detail pages and See All
    /// grids. Menu pops it before it opens the rail.
    private(set) var path: [TVPathEntry] = []
    /// Open to start with (Benjamin, 2026-10-01): the fold groups the
    /// libraries under one row, it doesn't hide them.
    var librariesExpanded = true

    mutating func select(_ row: Row) -> Selection {
        if row == .librariesGroup {
            librariesExpanded.toggle()
            return .toggledGroup
        }
        destination = row
        path = []
        return .navigated
    }

    @discardableResult
    mutating func push(_ route: AppRoute, id: UUID = UUID()) -> TVPathEntry {
        let entry = TVPathEntry(id: id, route: route)
        path.append(entry)
        return entry
    }

    mutating func pop() -> TVPathEntry? {
        path.popLast()
    }

    /// The one row the collapsed rail lets focus land on: the destination's,
    /// or the Libraries row standing in for a folded library, which has no
    /// row of its own in the collapsed rail.
    func railAnchor(libraries: [MediaItem]) -> Row {
        isFolded(destination, libraries: libraries) ? .librariesGroup : destination
    }

    /// Collapsed, only the anchor: Left from any height then lands on it.
    /// Open, every row.
    func focusableRows(isExpanded: Bool, libraries: [MediaItem]) -> Set<Row> {
        guard isExpanded else { return [railAnchor(libraries: libraries)] }
        return Set(TVSidebarLayout.rows(libraries: libraries, librariesExpanded: librariesExpanded))
    }

    /// The row focus should end on once it's in the rail: the destination's
    /// own. A folded destination opens the group again first, should it have
    /// been closed since, so the row is there to focus.
    mutating func enterRail(libraries: [MediaItem]) -> Row {
        if isFolded(destination, libraries: libraries) { librariesExpanded = true }
        return destination
    }

    /// The selected look: on the destination's row, or on the Libraries row
    /// while that row stands for it (the rail collapsed, or the group closed).
    func isHighlighted(_ row: Row, isExpanded: Bool, libraries: [MediaItem]) -> Bool {
        let groupStandsIn = isFolded(destination, libraries: libraries) && !(isExpanded && librariesExpanded)
        if row == .librariesGroup { return groupStandsIn }
        return row == destination && !groupStandsIn
    }

    private func isFolded(_ row: Row, libraries: [MediaItem]) -> Bool {
        guard case .library = row, case .folded = TVSidebarLayout.libraries(libraries) else { return false }
        return true
    }
}
