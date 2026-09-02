import SwiftUI
import os

/// A titled horizontal-scrolling row of posters, with an optional
/// "See All" link to the full collection.
///
/// Used on both the Home page and detail pages (`MovieDetailView`'s/
/// `ShowDetailView`'s "Included In"/"More Like This" rails),
/// so the `PosterCard`/`LandscapeMediaCard` choice below (see
/// `MediaCollectionRail.usesLandscapeTiles`) applies everywhere a rail
/// shows up, not just Home.
struct MediaRailView: View {
    /// Same `os.Logger` convention as `PlayerView`/`PlayerViewModel`/
    /// `HomeViewModel`. See the `ForEach` row body below for why a
    /// `.debug` log there is load-bearing, not incidental.
    private static let logger = Logger(subsystem: "com.dionysus.player", category: "MediaRailView")

    let rail: MediaCollectionRail

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
                .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                // The whole rail uses one tile shape or the other — see
                // `MediaCollectionRail.usesLandscapeTiles` — so every card
                // here is the same height and `.top` vs. the default
                // `.center` alignment makes no visible difference; `.top`
                // is just the more conventional choice for a shelf of
                // equal-height cards.
                //
                // `LazyHStack`, not `HStack` — a plain `HStack` constructs
                // and lays out every item up front regardless of whether
                // it's actually on screen, which for a 16-item rail meant
                // every one of its `AsyncRemoteImage`s fired its network
                // load immediately too. With several rails doing this at
                // once on Home's first load, that's dozens of simultaneous
                // image requests competing for the shared session's
                // connection pool — exactly the kind of burst
                // `RemoteImageLoader`'s retry logic exists to paper over,
                // rather than addressing the cause. `LazyHStack` defers
                // both construction and image loading until an item
                // actually scrolls into view.
                //
                // `usesLandscapeTiles` hoisted out of the loop — it's an
                // O(n) scan over `rail.items`, so reading it once per item
                // inside `ForEach` (an earlier version did) made rendering
                // a rail an accidental O(n²) instead of O(n).
                let usesLandscapeTiles = rail.usesLandscapeTiles
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(rail.items) { item in
                        // Load-bearing, not incidental — one of three
                        // matching log calls (with `HomeViewModel
                        // .performSoftRefresh()`/`.performFullLoad(
                        // resetLoadState:)` and `PosterCard
                        // .watchStatusOverlay`) that together fix a real,
                        // confirmed SwiftUI render-timing race: this row's
                        // body could run with the correct, freshly-updated
                        // `item` yet still paint a stale progress bar.
                        // See `HomeViewModel.performSoftRefresh()`'s
                        // identical log line for the full writeup, including
                        // what was tried and rejected before landing on
                        // this. Removing this call reintroduces the bug.
                        let _ = Self.logger.debug("row body: rail=\(rail.title, privacy: .public) id=\(item.id, privacy: .public) playedFraction=\(item.playedFraction ?? -1, privacy: .public)")
                        // `.id(item.playbackProgressIdentity)`, not just
                        // `item` (already the `ForEach` row's own identity
                        // via `Identifiable`) — same fix, same reasoning, as
                        // `MovieDetailView`/`ShowDetailView`'s identical use
                        // of `playbackProgressIdentity`: `MediaItem`'s own
                        // `Equatable` conformance only compares `dto.id`
                        // (`BaseItemDto`'s own `==`), so two `MediaItem`s
                        // for the same server item with *different*
                        // `userData` (a new resume position/percentage)
                        // read as equal to SwiftUI's diffing — confirmed
                        // live (2026-09-02): a rail card's progress bar
                        // stayed on its old position after
                        // `HomeViewModel.softRefresh()` correctly updated
                        // the underlying `MediaItem`, because nothing told
                        // this card's already-rendered view identity that
                        // anything about it needed to change. Forcing a
                        // fresh identity whenever the progress-relevant
                        // fields change is what actually gets the update
                        // painted, not just held in the model.
                        if usesLandscapeTiles {
                            LandscapeMediaCard(item: item)
                                .id(item.playbackProgressIdentity)
                        } else {
                            PosterCard(item: item)
                                .id(item.playbackProgressIdentity)
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    /// The title/"See All" row — when there's a `seeAllQuery`, the whole
    /// row is one tap target (title text included, not just the "See All"
    /// label) rather than only the small trailing link, so tapping
    /// anywhere across the header — not just the couple of words of
    /// "See All" — pushes the full collection.
    ///
    /// Wrapped in a (single-child) `ZStack`, not a bare `NavigationLink` —
    /// same bare-NavigationLink-in-a-Lazy-stack freeze fix as
    /// `PosterCard`/`LandscapeMediaCard`/`LibraryCard`/`HeroRailCard` (see
    /// `library-rail-navigationlink-freeze` memory). Rendered inside
    /// `HomeView`'s `LazyVStack` of rails, this row was live-confirmed to
    /// reproduce the freeze on a plain scroll (no navigation needed) before
    /// this wrap was added.
    @ViewBuilder
    private var header: some View {
        if let query = rail.seeAllQuery {
            ZStack {
                NavigationLink(value: AppRoute.collection(query)) {
                    headerLabel(showsSeeAll: true)
                }
                .buttonStyle(.plain)
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
