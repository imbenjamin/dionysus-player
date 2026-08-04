import SwiftUI
import UIKit

/// Backdrop image with a logo (or title text fallback) overlaid at the
/// bottom, Disney+-style.
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
        // The backdrop drives its own width via `.aspectRatio(.fill)` and
        // would otherwise blow out the layout (a 16:9 image at 320pt height is
        // ~569pt wide) — a `VStack` sizes itself to its widest child, so an
        // unconstrained image here would make the *entire* detail page that
        // wide. `GeometryReader` reads the width its parent actually offers
        // (with no oversized ideal-width opinion of its own, unlike the
        // image) and hands that to `.frame(width:)` explicitly, which is
        // what actually constrains the image — a `.frame(maxWidth: .infinity)`
        // alone doesn't override the ideal width the aspect-filled image
        // reports for the VStack's own sizing purposes.
        //
        // This used to be `.containerRelativeFrame(.horizontal)` instead of
        // `GeometryReader`, which resolves the same problem in principle but
        // in practice would get stuck reporting a stale (too-wide) size
        // after rotating portrait → landscape → portrait, overflowing the
        // screen on the way back. `GeometryReader.size` has no equivalent
        // container-lookup cache to go stale — it's read fresh every layout
        // pass — so it doesn't carry that failure mode.
        GeometryReader { proxy in
            AsyncRemoteImage(url: item.backdropImageURL ?? item.primaryImageURL)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
                .overlay {
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.85)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .overlay(alignment: .bottomLeading) {
                    Group {
                        if let logoURL = item.logoImageURL {
                            AsyncImage(url: logoURL) { phase in
                                if case .success(let image) = phase {
                                    image.resizable().aspectRatio(contentMode: .fit)
                                }
                            }
                            .frame(maxWidth: 240, maxHeight: 80, alignment: .leading)
                        } else {
                            Text(item.name)
                                .font(.largeTitle.bold())
                                .foregroundStyle(.white)
                        }
                    }
                    .padding()
                }
        }
        .frame(height: Self.height)
        .padding(.top, isLandscape ? 0 : statusBarInset)
    }
}
