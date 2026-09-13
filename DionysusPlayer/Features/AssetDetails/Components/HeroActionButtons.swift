import SwiftUI

/// The Show/Season/Episode entities `HeroActionButtons`' favorite and watched
/// buttons offer independently on a Show-content page — a Series, Season or
/// Episode, all rendered via `ShowDetailView`, whose call site resolves each.
/// `nil` means a Movie or standalone item, where `viewModel.item` is the only
/// thing to favorite or mark watched.
struct FavoriteWatchedShowScope {
    let show: MediaItem
    /// The selected season in `ShowDetailView`'s picker, `nil` while resolving,
    /// and omitted from the menu until then.
    let season: MediaItem?
    /// The episode in focus: that episode on an Episode-content page, or
    /// `AssetDetailViewModel.showPlaybackEpisode` on a Series/Season page. `nil`
    /// until resolved, and omitted from the menu then.
    let episode: MediaItem?
}

/// Favorite (star) and watched (eye) buttons as a trailing `ToolbarItem`,
/// mirroring the leading system back button. A real `ToolbarItem` gets the
/// pinned, floats-over-the-hero-at-rest behavior for free. Two rejected
/// alternatives: extra labeled controls alongside Play/Resume/Restart read as
/// too busy, with metadata actions competing with playback ones; and an
/// `.overlay` on the hero's top-trailing corner scrolled away with the hero
/// while the back button stayed pinned, the two visibly drifting apart.
///
/// Holds `viewModel` directly and reads `item`/`favoriteWatchedShowScope` as
/// computed properties rather than taking pre-resolved `MediaItem`s, so `body`
/// picks up `toggleFavorite`/`toggleWatched`'s eventual result without the
/// caller threading anything through.
///
/// The icon becomes a spinner (`isPending`) while a toggle for that item is in
/// flight. Without it, tapping Favorite looked like it did nothing: the write
/// succeeds immediately, but Jellyfin commits the userData change asynchronously
/// with variable latency — the same problem
/// `AssetDetailViewModel.refreshItem()` works around after playback — so a
/// refetch can race the commit and read back the old value.
/// `toggleFavorite`/`toggleWatched` poll until the server confirms, which can
/// take a couple of seconds.
///
/// The collapsed button uses plain `star`/`star.fill` and `eye.slash`/`eye.fill`
/// rather than the `.circle` variants `PosterCard.watchStatusOverlay` uses: this
/// button draws its own circular chrome, and the symbol's built-in circle then
/// renders as a second concentric circle clipped by the 44pt frame. The expanded
/// `Menu`'s rows are plain `Label`s in a system list, so they keep the `.circle`
/// variants.
///
/// Unwatched uses `eye.slash` rather than a plain `eye`, which read too close to
/// `eye.fill` at a glance; the slash reads as "off" as it does for
/// `CollectionGridView`'s Unwatched filter pill. The glyph shape carries the
/// state, with colour as a second signal once active: the filled star and
/// non-slashed eye take the same `.dionysusFavorite`/`.dionysusWatched` brand
/// colours `PosterCard.watchStatusOverlay` uses, while the inactive glyphs stay
/// uncoloured, so colour never appears without the shape agreeing.
///
/// With `favoriteWatchedShowScope` `nil` each is a plain toggle on `item`; on a
/// Show-content page each becomes a `Menu` offering Show/Season/Episode
/// independently with each row's own status — see `FavoriteWatchedShowScope`.
struct HeroActionButtons: View {
    let viewModel: AssetDetailViewModel
    /// `ShowDetailView`'s season-picker selection, left `nil` by
    /// `MovieDetailView` where `viewModel.seasons` is empty anyway. Taken here
    /// rather than resolved by the caller because `favoriteWatchedShowScope` must
    /// be a computed property reading `viewModel` directly, for the same
    /// reactivity reason as `item`.
    var selectedSeasonID: String? = nil

    private var item: MediaItem? { viewModel.item }
    private var isEpisodeContent: Bool { viewModel.item?.kind == .episode }

    /// See `FavoriteWatchedShowScope`. `nil` whenever `viewModel.seriesItem` is —
    /// a Movie, or a Show page that hasn't resolved it yet — and its
    /// `season`/`episode` are independently `nil` until each resolves.
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
            // `GlassEffectContainer` is the documented way to make nearby
            // `.glassEffect` shapes — `icon(_:isPending:)`, applied per button —
            // share one blended material pass, as in
            // `CollectionGridView.filterRow`.
            //
            // It is not what makes these two buttons merge into one pill at rest
            // with each circular boundary faintly visible inside it: that's
            // identical with or without the container, and with one
            // `ToolbarItem` or two. It's iOS 26's standard rendering for
            // adjacent circular glass toolbar controls, not a bug here.
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
                icon(item.isFavorite ? "star.fill" : "star", tint: item.isFavorite ? .dionysusFavorite : nil, isPending: isPending)
            }
            .accessibilityLabel(String(localized: "Favorite"))
            .accessibilityIdentifier(A11yID.AssetDetail.favoriteButton)
        } else {
            Button(action: { toggleFavorite(item) }) {
                icon(item.isFavorite ? "star.fill" : "star", tint: item.isFavorite ? .dionysusFavorite : nil, isPending: isPending)
            }
            .buttonStyle(.plain)
            .disabled(isPending)
            .accessibilityLabel(item.isFavorite ? String(localized: "Remove from Favorites") : String(localized: "Add to Favorites"))
            .accessibilityIdentifier(A11yID.AssetDetail.favoriteButton)
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
                icon(item.isPlayed ? "eye.fill" : "eye.slash", tint: item.isPlayed ? .dionysusWatched : nil, isPending: isPending)
            }
            .accessibilityLabel(String(localized: "Watched"))
            .accessibilityIdentifier(A11yID.AssetDetail.watchedButton)
        } else {
            Button(action: { toggleWatched(item) }) {
                icon(item.isPlayed ? "eye.fill" : "eye.slash", tint: item.isPlayed ? .dionysusWatched : nil, isPending: isPending)
            }
            .buttonStyle(.plain)
            .disabled(isPending)
            .accessibilityLabel(item.isPlayed ? String(localized: "Mark as Unwatched") : String(localized: "Mark as Watched"))
            .accessibilityIdentifier(A11yID.AssetDetail.watchedButton)
        }
    }

    private func favoriteMenuRow(for target: MediaItem, label: String) -> some View {
        Button {
            toggleFavorite(target)
        } label: {
            Label {
                Text(label)
            } icon: {
                Image(systemName: target.isFavorite ? "star.circle.fill" : "star.circle")
                    .foregroundStyle(target.isFavorite ? Color.dionysusFavorite : Color.primary)
            }
        }
        // Same guard as the collapsed button's `.disabled(isPending)`: without
        // it, re-opening the menu and tapping the same row while its toggle is
        // in flight fires a second, concurrent write.
        .disabled(viewModel.pendingFavoriteIDs.contains(target.id))
    }

    private func watchedMenuRow(for target: MediaItem, label: String) -> some View {
        Button {
            toggleWatched(target)
        } label: {
            // `eye.slash.circle`, not `eye.circle` — see this file's top-level
            // doc comment on the slashed glyph.
            Label {
                Text(label)
            } icon: {
                Image(systemName: target.isPlayed ? "eye.circle.fill" : "eye.slash.circle")
                    .foregroundStyle(target.isPlayed ? Color.dionysusWatched : Color.primary)
            }
        }
        // See `favoriteMenuRow`'s matching guard above.
        .disabled(viewModel.pendingWatchedIDs.contains(target.id))
    }

    private func toggleFavorite(_ target: MediaItem) {
        // `target.isFavorite` is not what gets sent below: this closure's
        // captured `target` goes stale, a confirmed toolbar bug, so the value is
        // read through `viewModel` instead — see
        // `AssetDetailViewModel.currentFavoriteWatchedStatus(forItemID:)`.
        // `target.id` is still used to identify which item, since an id doesn't
        // change across renders the way `isFavorite` does.
        let currentlyFavorite = viewModel.currentFavoriteWatchedStatus(forItemID: target.id)?.favorite ?? target.isFavorite
        // Registered via `viewModel.track(_:)` so `AssetDetailView`'s
        // `.onDisappear` can cancel this toggle's confirmation poll if the user
        // backs out mid-flight.
        viewModel.track(Task { await viewModel.toggleFavorite(itemID: target.id, currentlyFavorite: currentlyFavorite) })
    }

    private func toggleWatched(_ target: MediaItem) {
        // See `toggleFavorite(_:)` above.
        let currentlyWatched = viewModel.currentFavoriteWatchedStatus(forItemID: target.id)?.watched ?? target.isPlayed
        viewModel.track(Task { await viewModel.toggleWatched(itemID: target.id, currentlyWatched: currentlyWatched) })
    }

    /// The circular glyph chrome, shared with `AssetActionsButton` via
    /// `HeroToolbarGlyph`, which documents its glyph weight, the absence of an
    /// explicit color on iOS 26, and the fixed 44pt tap target.
    ///
    /// A non-`nil` `tint` is the one case a glyph here sets an explicit color,
    /// and only once the glyph is already in its filled shape — see
    /// `favoriteButton`/`watchedButton`.
    ///
    /// `isPending` swaps the glyph for a same-size spinner without changing the
    /// surrounding chrome; see this type's doc comment.
    private func icon(_ systemName: String, tint: Color? = nil, isPending: Bool) -> some View {
        HeroToolbarGlyph(systemName: systemName, tint: tint, isPending: isPending)
    }
}
