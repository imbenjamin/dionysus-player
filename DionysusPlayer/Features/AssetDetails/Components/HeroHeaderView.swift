import SwiftUI
import UIKit

/// Backdrop image with a logo (or title text fallback) overlaid at the
/// bottom, Disney+-style — see `BackdropLogoOverlay` for the shared visual
/// composition (also used by Home's hero rail).
///
/// Lives inside a `ScrollView` whose containing detail page applies
/// `.ignoresSafeArea(edges: .top)`, so this can render flush with the
/// screen's physical top edge once scrolled. At rest, though, that would put
/// the top of this image right behind the status bar/notch/Dynamic Island
/// cutout — the `.padding(.top, ...)` below reserves just enough space to
/// clear that at rest, while still letting the image scroll up through the
/// cutout once the user scrolls (the padding scrolls away with everything
/// else in the `ScrollView`, same as any other content). Landscape has no
/// such cutout to clear at the top, so the padding is skipped there.
struct HeroHeaderView: View {
    let item: MediaItem

    /// `@Environment` — not a plain computed property reading UIKit state
    /// directly — is what actually matters here. `statusBarInset` below
    /// *is* a plain computed property, and that's fine on its own: whatever
    /// calls it just gets a fresh read every time it's evaluated. The bug
    /// with two earlier attempts at `isLandscape` (checking
    /// `UIWindowScene.interfaceOrientation`, then comparing the key window's
    /// own `bounds`) wasn't that either signal was wrong — it's that SwiftUI
    /// has no idea `body` depends on either one, so it had no reason to
    /// *re-run* `body` on rotation at all. The padding value got computed
    /// once at first render and then sat frozen, whichever expression was
    /// there. `@Environment(\.verticalSizeClass)` is a tracked dependency:
    /// SwiftUI reruns `body` when it changes, which is what makes
    /// `statusBarInset` below get a fresh read too — the same expression
    /// that didn't work standalone works once *something* in this view is
    /// actually wired into SwiftUI's invalidation.
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var isLandscape: Bool { verticalSizeClass == .compact }

    /// Deliberately the raw window/hardware inset, not SwiftUI's ambient
    /// `safeAreaInsets` (via `GeometryReader`) — inside a `NavigationStack`,
    /// that value also folds in the visible navigation bar's height, which
    /// would push this down by more than just the status bar/cutout. The
    /// key window's own inset is unaffected by any app-level chrome drawn
    /// inside it.
    private var statusBarInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?
            .windows
            .first(where: \.isKeyWindow)?
            .safeAreaInsets.top ?? 0
    }

    private static let height: CGFloat = 320

    var body: some View {
        BackdropLogoOverlay(item: item)
            .frame(height: Self.height)
            .padding(.top, isLandscape ? 0 : statusBarInset)
    }
}
