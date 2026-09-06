import Foundation
import Observation

/// Announces that an item has just been deleted from the Jellyfin server, so
/// screens still holding a copy of it can drop or refresh it without each
/// having to re-fetch speculatively.
///
/// Needed because SwiftUI's navigation gives us no way to reach back up the
/// stack. Deleting an episode that was pushed as its own page pops back to
/// the show page below it — but that's a *different* `AssetDetailView` with
/// its own `AssetDetailViewModel`, and nothing tells it anything changed:
/// `HomeView`'s `.onChange(of: path)` refresh only fires on reaching the
/// stack *root*, not on a partial pop, and `MainTabView`'s path state isn't
/// reachable from `AppRouteDestinationView`. Without this the user watches
/// the episode they just deleted still sitting in the list underneath.
///
/// Follows the same plain-singleton convention as `ConnectivityMonitor
/// .shared`/`LibraryAvailability.shared`/`RecentPlaybackBroadcaster.shared`
/// — referenced directly from view/view-model code rather than routed
/// through SwiftUI's `Environment`.
///
/// Deliberately *not* folded into `RecentPlaybackBroadcaster`: that one's
/// `consume()` is single-shot by design (its own doc comment notes a second
/// consumer would need its own delivery mechanism), whereas a deletion has
/// several independent observers — the detail page underneath and any
/// library grid holding the row. So this exposes observable state and never
/// clears on read; observers key off `token` changing rather than racing
/// each other to take the value.
@MainActor
@Observable
final class DeletedItemBroadcaster {
    static let shared = DeletedItemBroadcaster()

    /// The most recently deleted item's id. Kept alongside `token` so an
    /// observer can tell *what* went away, not just that something did.
    private(set) var lastDeletedItemID: String?

    /// Bumped on every deletion. Observers watch this rather than
    /// `lastDeletedItemID` so that deleting the same id twice — possible
    /// across a re-fetch, and harmless — still registers as a fresh event.
    private(set) var token = UUID()

    private init() {}

    func record(itemID: String) {
        lastDeletedItemID = itemID
        token = UUID()
    }

    /// Test-only reset — mirrors `RecentPlaybackBroadcaster.reset()`/
    /// `LibraryAvailability.reset()`. Without it, the singleton carries one
    /// test's deletion into the next.
    func reset() {
        lastDeletedItemID = nil
        token = UUID()
    }
}
