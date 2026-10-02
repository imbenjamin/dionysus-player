import SwiftUI

extension EnvironmentValues {
    /// Pushes a detail page or a See All grid onto the shell's path.
    @Entry var tvOpenRoute: @MainActor (AppRoute) -> Void = { _ in }

    /// Switches the shell to a library's own page (Home's Libraries rail).
    /// It doesn't push: a library is a top-level page with its own rail row.
    @Entry var tvSelectLibrary: @MainActor (String) -> Void = { _ in }

    /// False for a page kept alive beneath the top one. A hidden page claims
    /// no focus and runs no timer; when it turns true again the page takes
    /// focus back and refreshes what may have changed above it.
    @Entry var tvPageIsOnShow = true
}
