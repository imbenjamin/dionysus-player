import SwiftUI

/// A titled horizontal-scrolling row of posters, with an optional
/// "See All" link to the full collection.
///
/// Used on both the Home page and detail pages (`MovieDetailView`'s/
/// `ShowDetailView`'s "Included In"/"More Like This" rails),
/// so the `PosterCard`/`LandscapeMediaCard` choice below (see
/// `MediaCollectionRail.usesLandscapeTiles`) applies everywhere a rail
/// shows up, not just Home.
struct MediaRailView: View {
    let rail: MediaCollectionRail

    /// Bumped by `HomeViewModel.railResetToken` on every hard refresh; this
    /// rail scrolls itself back to its first item whenever it changes, so a
    /// refreshed Home reads from item #1 like a fresh launch. Defaults to `0`
    /// for the detail-page rails, which are rebuilt per push and have nothing
    /// to reset.
    var resetToken: Int = 0

    /// Drives `posterWidth`/`landscapeWidth` below — `.regular` covers
    /// iPad in both orientations and iPhone Pro Max/Plus/Air models in
    /// landscape, all cases with meaningfully more width to spend than the
    /// `PosterCard`/`LandscapeMediaCard` defaults were sized for (those
    /// are iPhone numbers reused everywhere, leaving most of a wide iPad
    /// screen as dead space for a short rail like Continue Watching).
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// `PosterCard`'s default (130) is what `.compact` keeps; `.regular`
    /// scales up by the same ~1.23x ratio `LandscapeMediaCard` uses
    /// between its own portrait/landscape widths, rounded.
    private var posterWidth: CGFloat { horizontalSizeClass == .regular ? 160 : 130 }
    /// Same reasoning as `posterWidth`, scaled from `LandscapeMediaCard`'s
    /// 220 default.
    private var landscapeWidth: CGFloat { horizontalSizeClass == .regular ? 260 : 220 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
                .padding(.horizontal)

            railScrollView
        }
    }

    /// The horizontal shelf itself, wrapped in a `ScrollViewReader` so a hard
    /// refresh can send it back to its first item — see `resetToken`. The
    /// reader is only ever a one-shot nudge, exactly as in `HeroRailView`;
    /// nothing else here tracks scroll position.
    private var railScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                // The whole rail uses one tile shape or the other (see
                // `MediaCollectionRail.usesLandscapeTiles`), so `.top` vs.
                // the default `.center` alignment makes no visible
                // difference — `.top` just reads as more conventional for
                // a shelf of equal-height cards.
                //
                // `LazyHStack`, not `HStack` — `HStack` constructs and
                // lays out every item up front regardless of whether it's
                // on screen, which for a 16-item rail fired every
                // `AsyncRemoteImage`'s network load immediately. Several
                // rails doing that at once on Home's first load meant
                // dozens of simultaneous requests competing for the
                // shared session's connection pool. `LazyHStack` defers
                // both construction and image loading until an item
                // scrolls into view.
                //
                // `usesLandscapeTiles` hoisted out of the loop — reading
                // it (an O(n) scan) once per item inside `ForEach` made
                // rendering a rail an accidental O(n²) instead of O(n).
                let usesLandscapeTiles = rail.usesLandscapeTiles
                LazyHStack(alignment: .top, spacing: 12) {
                    // `id: \.railRowIdentity`, not `MediaItem`'s own
                    // `Identifiable` id — a row whose resume position
                    // changed has a different *identity*, which SwiftUI
                    // must act on. See that property's doc comment.
                    ForEach(rail.items, id: \.railRowIdentity) { item in
                        if usesLandscapeTiles {
                            LandscapeMediaCard(item: item, width: landscapeWidth)
                        } else {
                            PosterCard(item: item, width: posterWidth)
                        }
                    }
                }
            }
            // `.safeAreaPadding`, not `.padding` on the stack: the inset has
            // to belong to the scroll view rather than to its content, or
            // `scrollTo(_:anchor: .leading)` below aligns the first card
            // flush to the screen edge — 16pt short of where an unscrolled
            // rail actually rests. Visually identical otherwise.
            .safeAreaPadding(.horizontal, 16)
            .onChange(of: resetToken) { _, _ in
                guard let firstRowID = rail.items.first?.railRowIdentity else { return }
                // Unanimated: the rail's content was replaced wholesale in the
                // same update, so an animated scroll would slide across items
                // the user never saw in that order anyway.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo(firstRowID, anchor: .leading)
                }
            }
        }
    }

    /// The title/"See All" row — when there's a `seeAllQuery`, the whole
    /// row is one tap target (title text included, not just the "See All"
    /// label), so tapping anywhere across the header pushes the full
    /// collection.
    ///
    /// Wrapped in a (single-child) `ZStack`, not a bare `NavigationLink` —
    /// same bare-NavigationLink-in-a-Lazy-stack freeze fix as
    /// `PosterCard`/`LandscapeMediaCard`/`LibraryCard`/`HeroRailCard` (see
    /// `library-rail-navigationlink-freeze` memory).
    @ViewBuilder
    private var header: some View {
        if let query = rail.seeAllQuery {
            ZStack {
                NavigationLink(value: AppRoute.collection(query)) {
                    headerLabel(showsSeeAll: true)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(A11yID.Home.seeAll(query))
            }
        } else {
            headerLabel(showsSeeAll: false)
        }
    }

    private func headerLabel(showsSeeAll: Bool) -> some View {
        HStack {
            Text(rail.title)
                .font(.title3.bold())
                .foregroundStyle(.primary)

            Spacer()

            if showsSeeAll {
                Text("See All")
                    .font(.subheadline)
                    .foregroundStyle(Color.dionysusPrimary)
            }
        }
        .contentShape(Rectangle())
    }
}
