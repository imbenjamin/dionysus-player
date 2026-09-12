import SwiftUI

/// A Playlist's member items in stored order — `PlaylistDetailView`'s
/// counterpart to `CollectionItemList`, with the same two-tap-target row shape
/// and `NavigationLink` push per row, since a playlist member has its own
/// detail page.
///
/// Unlike a BoxSet, a Playlist can mix Movies and Episodes, and every row uses
/// the same landscape thumbnail regardless of kind (see `PlaylistItemRow`).
/// `railTitle`/`railSubtitle` absorb the metadata difference, so nothing here
/// branches on kind.
///
/// Doesn't fetch its own data: `items` is
/// `AssetDetailViewModel.orderedPlaylistItems`, already fetched and
/// music-filtered in `load()`/`refreshItem()`.
///
/// Lays out over two columns on regular width via `DetailRowGridMetrics`,
/// sizing from `.landscapeThumbnail` even for a Movie member where
/// `CollectionItemList` would use `.poster`. Owns its horizontal padding rather
/// than inheriting it from `PlaylistDetailView`, so `.onGeometryChange` below
/// measures the full width the list divides.
struct PlaylistItemList: View {
    let items: [MediaItem]
    /// Plays that item, joining the same Up Next chain as every other row and
    /// the page's Play/Resume button (see `PlaylistDetailView`). Distinct from
    /// tapping the row's text, which pushes into its detail page.
    var onPlayItem: (String) -> Void
    /// `nil` (no live session) omits every row's `DownloadButton` overlay, like
    /// `SeasonEpisodeList.EpisodeRow`.
    var client: JellyfinAPIClient?
    var userID: String?
    var downloadManager: DownloadManager?
    /// Owns `canEditPlaylist`/`removeFromPlaylist(_:)`/`track(_:)` for the
    /// per-row remove affordances. Passed whole rather than as loose
    /// closures, matching `HeroActionButtons(viewModel:)` in the same hierarchy.
    let viewModel: AssetDetailViewModel

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// This list's width, fed to `DetailRowGridMetrics`. See
    /// `SeasonEpisodeList.availableWidth` for why it's measured with
    /// `.onGeometryChange` rather than read off the window, and why 0 is a safe
    /// start.
    @State private var availableWidth: CGFloat = 0

    /// Set when a removal fails, notably `.notPermitted` if edit access was
    /// revoked mid-session (see `AssetDetailViewModel.removeFromPlaylist`). One
    /// shared alert rather than per-row state, since only one removal is in
    /// flight at a time.
    @State private var removalErrorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The count is the page's only length cue — the metadata row shows
            // total duration, not item count. "Items" rather than
            // `CollectionItemList`'s "Movies" because a Playlist mixes kinds.
            // Uninflected past one, like `DownloadsView`'s "\(count) Episodes".
            Text("\(items.count) Items")
                .font(.title3.bold())
                .padding(.horizontal)

            let metrics = DetailRowGridMetrics(
                containerWidth: availableWidth, isRegularWidth: horizontalSizeClass == .regular,
                artwork: .landscapeThumbnail
            )

            // A `LazyVGrid` only when there's more than one column; the
            // single-column case stays on a `LazyVStack`. Same split as
            // `SeasonEpisodeList` and `CollectionItemList`.
            if metrics.columnCount > 1 {
                LazyVGrid(columns: metrics.columns, alignment: .leading, spacing: 16) {
                    itemRows(metrics: metrics)
                }
                .padding(.horizontal)
            } else {
                LazyVStack(alignment: .leading, spacing: 16) {
                    itemRows(metrics: metrics)
                }
                .padding(.horizontal)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        .alert(
            "Couldn't remove item",
            isPresented: .init(get: { removalErrorMessage != nil }, set: { if !$0 { removalErrorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(removalErrorMessage ?? "")
        }
    }

    /// Shared by both branches above so the single- and multi-column lists
    /// can't drift apart.
    ///
    /// `id: \.playlistItemID`, not the default `Identifiable` keying: a playlist
    /// can contain the same item twice, so `item.id` isn't unique per row (see
    /// `MediaItem.playlistItemID`). Every item here has one, coming only from
    /// `AssetDetailViewModel.orderedPlaylistItems`.
    @ViewBuilder
    private func itemRows(metrics: DetailRowGridMetrics) -> some View {
        ForEach(items, id: \.playlistItemID) { item in
            PlaylistItemRow(
                item: item, onPlay: { onPlayItem(item.id) },
                thumbnailWidth: metrics.artworkWidth, thumbnailHeight: metrics.artworkHeight,
                client: client, userID: userID, downloadManager: downloadManager,
                canRemove: viewModel.canEditPlaylist,
                onRemove: {
                    viewModel.track(Task {
                        do {
                            try await viewModel.removeFromPlaylist(item)
                        } catch {
                            removalErrorMessage = error.localizedDescription
                        }
                    })
                }
            )
        }
    }
}

/// One playlist member, mirroring `CollectionItemList.CollectionItemRow`'s two
/// independent tap targets: the thumbnail plays the item, the text pushes into
/// its detail page.
///
/// Always landscape-shaped — `item.thumbImageURL`, falling back to the poster
/// cropped to the same 16:9 frame like `LandscapeMediaCard` — rather than
/// switching to a poster for a Movie member the way rail tiles do
/// (`MediaItem.usesLandscapeRailTile`); a uniform shape reads better in this
/// list. `railTitle`/`railSubtitle` absorb the kind difference: a Movie shows
/// its name and "year · duration", an Episode its series name and "S1:E4 ·
/// Episode Name".
private struct PlaylistItemRow: View {
    let item: MediaItem
    var onPlay: () -> Void
    /// Supplied by `DetailRowGridMetrics` rather than fixed here — see that type
    /// for why a two-column row can't keep a full-width row's 160x90 thumbnail.
    let thumbnailWidth: CGFloat
    let thumbnailHeight: CGFloat
    /// `nil` (no live session) omits the download button rather than showing one
    /// that can't resolve `playbackInfo`, like `EpisodeRow`'s identical trio.
    var client: JellyfinAPIClient?
    var userID: String?
    var downloadManager: DownloadManager?
    /// Whether the user may edit this row's playlist; gates `onRemove` entirely
    /// rather than showing a disabled control, like `AssetActionsButton`. See
    /// `AssetDetailViewModel.canEditPlaylist` for why it can't be a per-row
    /// server field the way `canDelete` is.
    var canRemove: Bool
    /// Fires the removal. Owned by `PlaylistItemList`, which wraps it in
    /// `viewModel.track(Task { ... })` and surfaces failures through its shared
    /// alert. Called from the `.contextMenu` item below rather than a swipe
    /// gesture: a hand-rolled swipe read as an ordinary tap against the Play
    /// `Button`/`NavigationLink` on device. A long-press menu is also already
    /// exposed to VoiceOver's rotor, Switch Control and Voice Control, so it
    /// needs no extra visible chrome.
    var onRemove: () -> Void

    /// Measured height of the title/subtitle block above the synopsis; see
    /// `overviewLineLimit`. 0 until the first layout pass reports.
    @State private var headerHeight: CGFloat = 0

    /// Line heights of the text styles this row stacks, used by
    /// `overviewLineLimit`. See `CollectionItemRow`'s identical pair for why
    /// they're `@ScaledMetric`.
    @ScaledMetric(relativeTo: .subheadline) private var titleLineHeight: CGFloat = 20
    @ScaledMetric(relativeTo: .caption) private var captionLineHeight: CGFloat = 16

    /// How many lines of synopsis fit under the title and subtitle within
    /// `thumbnailHeight`.
    ///
    /// Derived rather than a flat `lineLimit(6)`: six lines don't fit a 16:9
    /// thumbnail's 90pt at single-column size, so `.clipped()` sliced a line
    /// through its x-height instead of letting `Text` truncate.
    ///
    /// The reserved header is measured (`headerHeight`), not estimated from the
    /// title's `lineLimit(2)`. Estimating cost two lines: nearly every title
    /// here is one line (`railTitle` is a series name for an episode), so
    /// budgeting two reserved 60pt of a 90pt row against an actual ~35pt.
    /// Measuring also self-corrects — a title that does wrap shrinks the
    /// synopsis rather than pushing it under the clip.
    ///
    /// The fallback covers the first frame only, before `.onGeometryChange`
    /// reports, and is conservative, so a row only gains lines as it settles.
    ///
    /// This yields 3 lines at 90pt (compact width), 1 at an iPad portrait
    /// two-column row's 68pt, 3 at an iPad landscape row's 96pt.
    /// `CollectionItemRow` still uses the flat estimate: switching it would take
    /// its rows from 4 lines to the 6-line cap, a question about that page's
    /// prose rather than a bug.
    private var overviewLineLimit: Int {
        let reserved = headerHeight > 0
            ? headerHeight
            : titleLineHeight * 2 + captionLineHeight + 4
        return max(1, min(6, Int((thumbnailHeight - reserved - 4) / captionLineHeight)))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // A `ZStack`, not the download button inside the Play `Button`'s
            // label: a nested button risks its taps being swallowed by the
            // outer one. Same split as `EpisodeRow`.
            //
            // `.bottomTrailing` because this thumbnail's corner scheme is
            // favorite (top-left) / watched (top-right) / show logo
            // (bottom-left) / download (bottom-right), and `watchStatusOverlay`
            // already owns top-right.
            ZStack(alignment: .bottomTrailing) {
                Button(action: onPlay) {
                    ZStack {
                        AsyncRemoteImage(
                            url: item.thumbImageURL ?? item.primaryImageURL,
                            placeholderSystemImage: item.kind.placeholderSystemImage
                        )
                        .frame(width: thumbnailWidth, height: thumbnailHeight)
                        // Same show-logo treatment as `LandscapeMediaCard`,
                        // self-gated to `.episode` items with a logo. Applied
                        // before the Play button's glyph (a `ZStack` sibling, not
                        // part of this `.overlay` chain), so the logo sits
                        // bottom-left underneath it.
                        .episodeLogoOverlay(for: item)
                        .watchStatusOverlay(for: item)
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                        Circle()
                            .fill(.black.opacity(0.55))
                            .frame(width: 36, height: 36)
                            .overlay {
                                Image(systemName: "play.fill")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.white)
                            }
                    }
                }
                .buttonStyle(.plain)
                // A plain `Button` already reads as one VoiceOver element with
                // the `.isButton` trait, so only a label is needed.
                .accessibilityLabel(String(localized: "Play \(item.railTitle)"))

                // The same component the detail page's Play/Resume row uses, at
                // full parity, not a slimmed-down copy. `item.episodeLabel` is
                // `nil` for a Movie member, falling back to the bare state word.
                if let client, let userID, let downloadManager {
                    DownloadButton(
                        item: item, client: client, userID: userID, downloadManager: downloadManager, style: .overlay,
                        accessibilityContext: item.episodeLabel
                    )
                        .padding(4)
                }
            }

            // See `PosterCard.body` for why the `NavigationLink` needs its own
            // `ZStack` wrapper inside a `LazyVStack` rather than sitting bare in
            // this `HStack`.
            ZStack(alignment: .topLeading) {
                NavigationLink(value: AppRoute.assetDetail(itemID: item.id, preloadedItem: item)) {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            // Title and subtitle measured as one block, so
                            // `overviewLineLimit` divides what's actually left.
                            // The synopsis stays outside this stack: measuring
                            // it would make the limit depend on its own result.
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.railTitle)
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)

                                if let subtitle = item.railSubtitle {
                                    Text(subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }

                            if let overview = item.overview {
                                Text(overview)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(overviewLineLimit)
                            }
                        }

                        Spacer(minLength: 0)

                        // Decorative "this opens something" cue.
                        Image(systemName: "chevron.right")
                            .font(.caption.bold())
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Caps the text column to the thumbnail's height,
                    // top-aligned. See `CollectionItemRow`'s identical
                    // `.frame`/`.clipped()` pair for why a `lineLimit` alone
                    // doesn't enforce it.
                    .frame(height: thumbnailHeight, alignment: .top)
                    .clipped()
                    .contentShape(Rectangle())
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(item.accessibilityDescription)
                    .accessibilityAddTraits(.isButton)
                    // What a UI test long-presses to reveal this row's
                    // `.contextMenu` — see `A11yID.Playlist.row(_:)` for why a
                    // label alone can't disambiguate one row among several.
                    .accessibilityIdentifier(A11yID.Playlist.row(item.playlistItemID ?? item.id))
                }
                .buttonStyle(.plain)
            }
        }
        .contextMenu {
            // The only removal path. `.contextMenu` items are exposed to
            // VoiceOver's rotor, Switch Control and Voice Control
            // automatically, so removal is reachable without a gesture and
            // without extra chrome on an already-dense row. Omitted rather
            // than disabled when `canRemove` is false, like
            // `AssetActionsButton` does for `canDelete`.
            //
            // A hand-rolled swipe-to-remove was tried and reverted: it read as
            // an ordinary tap against the Play `Button`/`NavigationLink`, and
            // felt clunky next to a native swipe even with
            // `.highPriorityGesture`.
            if canRemove {
                Button(role: .destructive) {
                    onRemove()
                } label: {
                    Label("Remove from Playlist", systemImage: "minus.circle")
                }
                .accessibilityIdentifier(A11yID.Playlist.removeMenuItem(item.playlistItemID ?? item.id))
            }
        }
    }
}
