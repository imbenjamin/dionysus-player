import Observation

/// App-wide mirror of `HomeViewModel.loadState` — Home is the one screen
/// that always tries to load real content the moment the app opens, so
/// it's the natural place to detect "can we actually use this server right
/// now" (see `HomeViewModel.retryLoadIfNeeded()`'s own doc comment for why
/// that's a meaningfully different, more specific question than
/// `ConnectivityMonitor.isOffline` alone — reconnecting Wi-Fi can report
/// "online" before the actual `/Users/{id}/Views` fetch can succeed).
///
/// `SearchView`'s landing page (before any query is typed, so it has no
/// network activity of its own to fail) reads `state` directly to mirror
/// Home's own offline/loading/available handling instead of duplicating
/// it, and calls `retryAction` for its own "Try Again" button rather than
/// needing a reference to `HomeViewModel` — same closure-hook shape as
/// `DownloadManager.onRowMarkedForDeletion`. Both are wired up by
/// `HomeView` once its own `HomeViewModel` exists; nothing else writes to
/// this type.
///
/// Follows the same plain-singleton convention as `ConnectivityMonitor
/// .shared` — referenced directly in view bodies rather than routed
/// through SwiftUI's `Environment`, which Observation still tracks
/// correctly.
@MainActor
@Observable
final class LibraryAvailability {
    enum State: Equatable {
        /// Home has never successfully loaded yet this session — either its
        /// very first load is still in flight, or a reconnect retry is
        /// currently working through `HomeViewModel.reconnectRetrySchedule`.
        /// Deliberately distinct from `.unavailable`: neither is "ready",
        /// but only one of them is actually an offline/error condition
        /// worth telling the user about.
        case loading
        case available
        case unavailable
    }

    static let shared = LibraryAvailability()

    private(set) var state: State = .loading
    /// Set by `HomeView` to `HomeViewModel.retryLoadIfNeeded()` (not a bare
    /// `load()` — coalesces with any retry already in flight rather than
    /// racing it, see that method's doc comment) once its view model
    /// exists — `nil` before then, which `SearchView` never actually
    /// reaches in practice, since `state` still reads `.loading` at that
    /// point too.
    var retryAction: (() -> Void)?

    private init() {}

    /// No-ops if the value wouldn't change — see `ConnectivityMonitor
    /// .reportFailure()`'s doc comment: `@Observable`'s change tracking
    /// fires on every assignment regardless of whether the value actually
    /// differs, and this is read directly in `SearchView`'s body.
    func update(_ state: State) {
        guard self.state != state else { return }
        self.state = state
    }

    /// Test-only reset — `private(set)` blocks direct assignment even from
    /// a `@testable import`, so tests need this instead.
    func reset() {
        state = .loading
        retryAction = nil
    }
}
