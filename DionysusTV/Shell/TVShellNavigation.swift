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

    /// Drops every pushed page, returning them deepest first: deleting a
    /// show's last episode leaves nothing beneath to go back to
    /// (`AssetDetailViewModel.DeletionOutcome.popToRoot`).
    mutating func popToRoot() -> [TVPathEntry] {
        defer { path = [] }
        return path.reversed()
    }

    /// Pops `entryID`'s page only while it's on top. A deletion's outcome
    /// lands after its request, by when Menu may have taken the user
    /// elsewhere; popping whatever was on top then left the wrong page.
    mutating func pop(_ entryID: UUID) -> TVPathEntry? {
        path.last?.id == entryID ? path.popLast() : nil
    }

    /// `popToRoot()`, only while `entryID`'s page is still in the path.
    mutating func popToRoot(from entryID: UUID) -> [TVPathEntry] {
        path.contains { $0.id == entryID } ? popToRoot() : []
    }

    /// Search is the system's own full-screen layout (Benjamin, 2026-10-04):
    /// its keyboard and field are laid out for the whole width, and beside
    /// the rail the field's hint ran off the screen. So there the collapsed
    /// rail slides off the left edge, and Menu slides the open sidebar in.
    /// A page pushed from Search sits beside the rail as any other does.
    var hidesCollapsedRail: Bool { destination == .search && path.isEmpty }

    /// The page choosing `row` leaves for another, which starts fresh when
    /// it's next chosen (Benjamin, 2026-10-04 for Search, 2026-10-20 for every
    /// page): Search with an empty field, a library unfiltered at its top,
    /// Home on the hero with a hard refresh. Folding the Libraries group and
    /// choosing the page's own row stay on it (from a pushed page, that only
    /// drops the path: a return, as Menu's is).
    func pageLeft(choosing row: Row) -> Row? {
        row == destination || row == .librariesGroup ? nil : destination
    }

    /// A chevron at the middle of the left edge says where the rail went
    /// (Benjamin, 2026-10-04): shown while it's off screen, gone once open.
    func showsEdgeChevron(isExpanded: Bool) -> Bool { hidesCollapsedRail && !isExpanded }

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
