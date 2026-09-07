import SwiftUI

/// Unwinds a whole `NavigationStack`, rather than popping one level.
///
/// `@MainActor @Sendable` so `PopNavigationToRootKey.defaultValue` can be a
/// `nonisolated static let` without tripping Swift 6's concurrency checking.
/// The action only ever mutates `MainTabView`'s navigation path, which is
/// main-actor state regardless, so the isolation costs callers nothing.
typealias PopToRootAction = @MainActor @Sendable () -> Void

/// A way for a pushed screen to unwind its whole `NavigationStack`, not just
/// pop one level.
///
/// `@Environment(\.dismiss)` covers the one-level case, and is what nearly
/// everything in the app wants. This exists for the case that genuinely
/// needs more: deleting the last episode of a show from that episode's own
/// page leaves the show page directly underneath showing content that no
/// longer exists (and which Jellyfin drops entirely once its last episode
/// goes), so popping onto it would land the user on a dead screen. Skipping
/// straight to the tab root is the only destination guaranteed to still be
/// valid.
///
/// Injected by whoever owns the stack's path — only `MainTabView` does, for
/// Home and Search. It stays `nil` everywhere else (the Downloads tab's
/// `NavigationStack` has no path binding at all, and `ProfileView` owns its
/// own container that differs by device), and callers are expected to fall
/// back to `dismiss()` rather than treating absence as an error.
private struct PopNavigationToRootKey: EnvironmentKey {
    static let defaultValue: PopToRootAction? = nil
}

extension EnvironmentValues {
    var popNavigationToRoot: PopToRootAction? {
        get { self[PopNavigationToRootKey.self] }
        set { self[PopNavigationToRootKey.self] = newValue }
    }
}
