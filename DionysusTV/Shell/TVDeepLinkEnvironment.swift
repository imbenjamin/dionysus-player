import SwiftUI

extension EnvironmentValues {
    /// A link for `TVMainView` to apply (`DeepLink`, decided by
    /// `DeepLinkRouter`); set by `TVRootView`, which clears it once applied.
    @Entry var tvPendingDeepLink: DeepLink? = nil
    @Entry var tvDeepLinkApplied: @MainActor () -> Void = {}
}
