import SwiftUI

/// The Show/Season/Episode entities `HeroActionButtons`' favorite/watched
/// buttons offer independently when they're on a Show-content page (Series
/// tapped directly, a Season, or an Episode — all three render via
/// `ShowDetailView`) — see that view's call site for how each is resolved.
/// `nil` (`HeroActionButtons.favoriteWatchedShowScope` when
/// `viewModel.seriesItem` is `nil`) means a Movie or standalone item
/// instead, where there's only ever one thing to favorite/mark watched:
/// `viewModel.item` itself.
struct FavoriteWatchedShowScope {
    let show: MediaItem
    /// The currently-selected season in `ShowDetailView`'s picker, or `nil`
    /// while it's still resolving — omitted from the menu until then.
    let season: MediaItem?
    /// The episode currently in focus — that specific episode on an
    /// Episode-content page, or `AssetDetailViewModel.showPlaybackEpisode`
    /// on a Series/Season-content page (`nil` until that resolves, same as
    /// `season`). Omitted from the menu when `nil`.
    let episode: MediaItem?
}

/// Favorite (star) and watched (eye) buttons, placed as a trailing
/// `ToolbarItem` — the mirror image of the system back button, which is a
/// *leading* nav bar item. Tried first as a labeled third/fourth control
/// alongside Play/Resume/Restart (`PlayResumeButtonRow`), in one row and then
/// two — both read as too busy, with metadata actions (what this page's
/// content *is*) competing for attention with playback actions (what happens
/// when you tap Play). Tried next as a manual `.overlay` on the hero image's
/// top-trailing corner, positioned to visually line up with the back
/// button — closer, but an `.overlay` on the hero scrolls away with it,
/// while the back button (real nav bar chrome) stays pinned in place as the
/// page scrolls underneath; the two drifting apart as soon as you scrolled
/// read as broken. A real `ToolbarItem` is what actually gets that pinned,
/// floats-over-the-hero-at-rest/gains-a-background-once-scrolled behavior
/// for free, with no manual position math needed — see this view's call
/// sites (`ShowDetailView`, `MovieDetailView`) for how it's wired in.
///
/// Holds `viewModel` directly and reads `item`/`favoriteWatchedShowScope`
/// from it as computed properties, rather than receiving pre-resolved
/// `MediaItem` values from the caller — this is what lets `body` pick up
/// `AssetDetailViewModel.toggleFavorite`/`toggleWatched`'s eventual result
/// without the caller having to thread anything through manually.
///
/// The icon briefly becomes a spinner (`isPending` below) while a toggle for
/// that specific item is in flight — necessary, not just nice-to-have:
/// tracked down a real bug live where tapping Favorite looked like it did
/// nothing at all. The write itself (`setFavorite`/`setWatched`) always
/// succeeded immediately (confirmed with direct-to-server requests), but
/// Jellyfin commits that userData change asynchronously afterward with
/// variable latency (same issue `AssetDetailViewModel.refreshItem()` already
/// works around for the Play/Resume button after a playback session) — a
/// refetch straight after the write can race that commit and read back the
/// *old* value. `AssetDetailViewModel.toggleFavorite`/`toggleWatched` now
/// poll until the server actually confirms the new value, which fixes
/// correctness but means the round trip can genuinely take a couple of
/// seconds — the spinner is what keeps that from reading as a broken tap
/// in the meantime.
///
/// The collapsed button itself uses plain `star`/`star.fill` and
/// `eye`/`eye.fill` — not the `.circle` variants `PosterCard
/// .watchStatusOverlay`'s badges use — deliberately: this button already
/// draws its own circular chrome (`icon(_:)` below), and stacking the SF
/// Symbol's *own* built-in circle inside that would draw two concentric
/// circles, with the glyph's own circle getting clipped by the 44pt frame
/// rather than reading as an intentional layered look (confirmed live —
/// visibly cut off). The expanded `Menu`'s list rows
/// (`favoriteMenuRow`/`watchedMenuRow` below) don't have that problem —
/// they're plain `Label`s in a system list, not squeezed into a fixed-size
/// circular container — so those keep the `.circle` variants, matching
/// `watchStatusOverlay`'s badges the way the collapsed button used to.
/// State is communicated by the glyph itself (outline vs. filled), not by
/// tinting the circle behind it. On a Movie/Episode-content page
/// (`favoriteWatchedShowScope` `nil`) each is a plain toggle on `item`
/// itself; on a Show-content page each becomes a `Menu` offering the
/// Show/Season/Episode independently, each row showing its own current
/// status — see `FavoriteWatchedShowScope`.
struct HeroActionButtons: View {
    let viewModel: AssetDetailViewModel
    /// `ShowDetailView`'s season-picker selection — only meaningful there;
    /// left at its default `nil` on `MovieDetailView`'s call site, where
    /// `viewModel.seasons` is always empty anyway so it wouldn't match
    /// anything. Needed here (rather than resolved by the caller) because
    /// `favoriteWatchedShowScope` below has to be a computed property reading
    /// `viewModel` directly for the same reactivity reason as `item` — see
    /// this type's doc comment.
    var selectedSeasonID: String? = nil

    private var item: MediaItem? { viewModel.item }
    private var isEpisodeContent: Bool { viewModel.item?.kind == .episode }

    /// See `FavoriteWatchedShowScope`'s doc comment — `nil` whenever
    /// `viewModel.seriesItem` is (a Movie, or a Show-content page that
    /// hasn't resolved it yet); `season`/`episode` inside it are
    /// independently `nil` until *their* own resolution catches up.
    private var favoriteWatchedShowScope: FavoriteWatchedShowScope? {
        viewModel.seriesItem.map {
            FavoriteWatchedShowScope(
                show: $0,
                season: viewModel.seasons.first(where: { $0.id == selectedSeasonID }),
                episode: isEpisodeContent ? viewModel.item : viewModel.showPlaybackEpisode
            )
        }
    }

    var body: some View {
        if let item {
            // `GlassEffectContainer` — same reasoning as
            // `CollectionGridView.filterRow`'s own use of one for its
            // adjacent pills — is the documented way to make multiple
            // nearby `.glassEffect` shapes (`icon(_:isPending:)` below,
            // applied to each button independently) share one blended
            // material pass instead of two independent, potentially-
            // overlapping ones, so it stays here on principle even though
            // it turned out not to be the fix for one specific visual
            // question: at rest, these two buttons still automatically
            // merge into one continuous pill *with each one's own circular
            // boundary faintly visible inside it* — confirmed live that
            // this is unrelated to the container (identical either way),
            // and unrelated to this being one `ToolbarItem` vs. two
            // separate ones (also identical either way) — it's iOS 26's
            // own standard rendering for multiple adjacent circular glass
            // toolbar controls, the same way a merged pair of nav bar
            // buttons elsewhere in iOS 26 shows each control's own subtle
            // division within the shared capsule. Not a bug in this view.
            if #available(iOS 26.0, *) {
                GlassEffectContainer(spacing: 12) {
                    HStack(spacing: 12) {
                        favoriteButton(item: item)
                        watchedButton(item: item)
                    }
                }
            } else {
                HStack(spacing: 12) {
                    favoriteButton(item: item)
                    watchedButton(item: item)
                }
            }
        }
    }

    @ViewBuilder
    private func favoriteButton(item: MediaItem) -> some View {
        let isPending = viewModel.pendingFavoriteIDs.contains(item.id)
        if let scope = favoriteWatchedShowScope {
            Menu {
                favoriteMenuRow(for: scope.show, label: scope.show.name)
                if let season = scope.season {
                    favoriteMenuRow(for: season, label: season.name)
                }
                if let episode = scope.episode {
                    favoriteMenuRow(for: episode, label: episode.episodeLabel.map { "\($0)  \(episode.name)" } ?? episode.name)
                }
            } label: {
                icon(item.isFavorite ? "star.fill" : "star", isPending: isPending)
            }
        } else {
            Button(action: { toggleFavorite(item) }) {
                icon(item.isFavorite ? "star.fill" : "star", isPending: isPending)
            }
            .buttonStyle(.plain)
            .disabled(isPending)
        }
    }

    @ViewBuilder
    private func watchedButton(item: MediaItem) -> some View {
        let isPending = viewModel.pendingWatchedIDs.contains(item.id)
        if let scope = favoriteWatchedShowScope {
            Menu {
                watchedMenuRow(for: scope.show, label: scope.show.name)
                if let season = scope.season {
                    watchedMenuRow(for: season, label: season.name)
                }
                if let episode = scope.episode {
                    watchedMenuRow(for: episode, label: episode.episodeLabel.map { "\($0)  \(episode.name)" } ?? episode.name)
                }
            } label: {
                icon(item.isPlayed ? "eye.fill" : "eye", isPending: isPending)
            }
        } else {
            Button(action: { toggleWatched(item) }) {
                icon(item.isPlayed ? "eye.fill" : "eye", isPending: isPending)
            }
            .buttonStyle(.plain)
            .disabled(isPending)
        }
    }

    private func favoriteMenuRow(for target: MediaItem, label: String) -> some View {
        Button {
            toggleFavorite(target)
        } label: {
            Label(label, systemImage: target.isFavorite ? "star.circle.fill" : "star.circle")
        }
    }

    private func watchedMenuRow(for target: MediaItem, label: String) -> some View {
        Button {
            toggleWatched(target)
        } label: {
            Label(label, systemImage: target.isPlayed ? "eye.circle.fill" : "eye.circle")
        }
    }

    private func toggleFavorite(_ target: MediaItem) {
        Task { await viewModel.toggleFavorite(itemID: target.id, currentlyFavorite: target.isFavorite) }
    }

    private func toggleWatched(_ target: MediaItem) {
        Task { await viewModel.toggleWatched(itemID: target.id, currentlyWatched: target.isPlayed) }
    }

    /// Same circular chrome as `ResetFiltersButton` (`CollectionGridView`) —
    /// real Liquid Glass on iOS 26, a plain filled circle as the pre-26
    /// fallback — sized to match the system back button it sits opposite.
    /// `isPending` swaps the glyph for a spinner, same size, without
    /// changing the surrounding chrome — see this type's doc comment for why.
    ///
    /// Deliberately no explicit `.foregroundStyle`/`.tint` on the glyph
    /// (iOS 26 branch only) — a hardcoded black glyph was tried first, on
    /// the assumption it'd match the back button's chevron, but that button
    /// doesn't set an explicit color either, and confirmed live
    /// (2026-08-11) that's exactly why it — unlike this button once it *did*
    /// hardcode black — stays legible over both a light and a dark patch of
    /// the scrolling hero image: real `.glassEffect` content is
    /// automatically tinted for contrast against whatever's currently
    /// behind the glass, the same Liquid Glass vibrancy the system back
    /// button gets for free. Forcing `.black` (or `.white`) defeats that and
    /// pins the glyph to one color regardless of what's under it. The pre-26
    /// fallback below has no such live-contrast mechanism to defer to —
    /// `.primary` there just tracks light/dark *mode*, not the image behind
    /// it — so it keeps an explicit color, chosen to read clearly against
    /// its own opaque background fill instead.
    ///
    /// `.body`/`.medium` — not the `20pt`/`.semibold` this started at —
    /// after direct feedback that the original read as too thick/heavy to
    /// pass for native chrome: the back button's own chevron (and this
    /// glyph's closest real-world equivalent, the favorite/watched icons in
    /// Apple's own Podcasts/TV apps) sit closer to this weight, with more
    /// glyph-to-circle breathing room than a bigger/bolder glyph leaves.
    /// The 44pt frame stays fixed either way — shrinking the glyph doesn't
    /// shrink the tap target, just how much of the circle it visually fills.
    @ViewBuilder
    private func icon(_ systemName: String, isPending: Bool) -> some View {
        if #available(iOS 26.0, *) {
            Group {
                if isPending {
                    ProgressView()
                } else {
                    Image(systemName: systemName)
                        .font(.body.weight(.medium))
                }
            }
            .frame(width: 44, height: 44)
            .glassEffect(.regular.interactive(), in: Circle())
        } else {
            // Matches `ResetFiltersButton`'s pre-26 fallback — a light fill
            // a black glyph reads clearly against, not the dark fill this
            // used before the glyph itself switched from white to black.
            Group {
                if isPending {
                    ProgressView()
                        .tint(.black)
                } else {
                    Image(systemName: systemName)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.black)
                }
            }
            .frame(width: 44, height: 44)
            .background(Color(.secondarySystemBackground))
            .clipShape(Circle())
        }
    }
}
