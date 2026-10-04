import Observation

/// App-wide mirror of `HomeViewModel.loadState`. Home always loads real content
/// at launch, making it the place to answer "is this server usable now" — a
/// narrower question than `ConnectivityMonitor.isOffline`, since reconnecting
/// Wi-Fi reports online before `/Users/{id}/Views` can succeed.
///
/// `SearchView`'s landing page has no network activity of its own to fail, so
/// it reads `state` and calls `retryAction` rather than duplicating Home's
/// handling or holding a `HomeViewModel`. `HomeView` wires both up; nothing
/// else writes here.
///
/// A plain singleton like `ConnectivityMonitor.shared`, referenced directly in
/// view bodies rather than through `Environment`; Observation still tracks it.
@MainActor
@Observable
final class LibraryAvailability {
    enum State: Equatable {
        /// Home has not loaded yet this session: either the first load is in
        /// flight or a retry is working through
        /// `HomeViewModel.reconnectRetrySchedule`. Distinct from
        /// `.unavailable` — neither is ready, but only that one is worth
        /// reporting to the user.
        case loading
        case available
        case unavailable
    }

    static let shared = LibraryAvailability()

    private(set) var state: State = .loading
    /// Set by `HomeView` to `HomeViewModel.retryLoadIfNeeded()`, which
    /// coalesces with an in-flight retry rather than racing it. `nil` until the
    /// view model exists, which `SearchView` never observes because `state`
    /// still reads `.loading` then.
    var retryAction: (() -> Void)?

    private init() {}

    /// No-ops when unchanged: `@Observable` fires on every assignment, equal or
    /// not, and `SearchView`'s body reads this directly.
    func update(_ state: State) {
        guard self.state != state else { return }
        self.state = state
    }

    /// Test-only reset; `private(set)` blocks assignment even under
    /// `@testable import`.
    func reset() {
        state = .loading
        retryAction = nil
    }
}
