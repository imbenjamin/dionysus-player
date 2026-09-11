import Foundation
import Observation

/// Announces that an item was deleted from the server, so screens still holding
/// a copy can drop or refresh it without re-fetching speculatively.
///
/// SwiftUI navigation offers no way to reach back up the stack. Deleting an
/// episode pushed as its own page pops to the show page below, a different
/// `AssetDetailView` with its own view model that nothing informs:
/// `HomeView`'s `.onChange(of: path)` fires only at the stack root, and
/// `MainTabView`'s path isn't reachable from `AppRouteDestinationView`.
///
/// Separate from `RecentPlaybackBroadcaster`, whose `consume()` is single-shot:
/// a deletion has several independent observers — the detail page underneath
/// and any library grid holding the row — so this exposes observable state and
/// never clears on read, with observers keying off `token`.
@MainActor
@Observable
final class DeletedItemBroadcaster {
    static let shared = DeletedItemBroadcaster()

    /// The most recently deleted item's id, so an observer can tell what went
    /// away rather than only that something did.
    private(set) var lastDeletedItemID: String?

    /// Bumped on every deletion. Observers watch this rather than
    /// `lastDeletedItemID` so deleting the same id twice, possible across a
    /// re-fetch, still registers as a fresh event.
    private(set) var token = UUID()

    private init() {}

    func record(itemID: String) {
        lastDeletedItemID = itemID
        token = UUID()
    }

    /// Test-only reset; without it the singleton carries one test's deletion
    /// into the next.
    func reset() {
        lastDeletedItemID = nil
        token = UUID()
    }
}
