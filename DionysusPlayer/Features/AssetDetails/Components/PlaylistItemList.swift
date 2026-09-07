import SwiftUI

/// A Playlist's own member items, in the playlist's own stored order —
/// `PlaylistDetailView`'s counterpart to `CollectionDetailView`'s
/// `CollectionItemList`, same two-independent-tap-targets row shape and the
/// same `NavigationLink`-push-per-row navigation (a Playlist's members
/// already have their own full detail pages, same as a BoxSet's — see
/// `PlaylistItemRow`'s doc comment). Unlike a BoxSet's members, though, a
/// Playlist can mix Movies and Episodes together — every row uses the same
/// landscape thumbnail shape regardless of kind (a deliberate uniformity
/// choice, unlike `PosterCard`/`LandscapeMediaCard`'s kind-dependent split
/// elsewhere in the app — see `PlaylistItemRow`'s doc comment), with
/// `railTitle`/`railSubtitle` handling the metadata difference instead, so
/// nothing here needs to special-case which kind a given row actually is.
///
/// Doesn't fetch its own data — `items` is
/// `AssetDetailViewModel.orderedPlaylistItems`, already fetched (and
/// audio/music-filtered) alongside `similar`/`collections` in `load()`/
/// `refreshItem()`.
///
/// Lays out over two columns on regular width, via the same
/// `DetailRowGridMetrics` the episode and collection lists use — see that
/// type for why, and for the measurements behind it. Every row here is
/// landscape-shaped whatever kind it holds (see this type's doc comment
/// above), so it sizes from `.landscapeThumbnail` even for a Movie
/// member, where `CollectionItemList` would use `.poster`. Owns its own
/// horizontal padding rather than taking it from `PlaylistDetailView`
/// (which is how it used to work), so that what `.onGeometryChange`
/// measures below is the full width the list has to divide, matching what
/// the metrics type expects.
struct PlaylistItemList: View {
    let items: [MediaItem]
    /// Plays that item, joining the same Up Next chain as every other row
    /// and the page's own Play/Resume button — see `PlaylistDetailView`'s
    /// doc comment for why a single shared queue covers all three. Distinct
    /// from tapping the row's text, which pushes into that item's own
    /// detail page instead.
    var onPlayItem: (String) -> Void
    /// `nil` (no live session) omits every row's `DownloadButton` overlay
    /// entirely — same graceful-degradation shape `SeasonEpisodeList.EpisodeRow`
    /// already uses for the same reason.
    var client: JellyfinAPIClient?
    var userID: String?
    var downloadManager: DownloadManager?

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// This list's own width, fed to `DetailRowGridMetrics` below. See
    /// `SeasonEpisodeList.availableWidth` for why this is measured with
    /// `.onGeometryChange` rather than read from `UIScreen`/`keyWindow`,
    /// and why starting at 0 is safe.
    @State private var availableWidth: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The count carries real information here that "Items" alone
            // doesn't — a Playlist has no other length cue on the page
            // (the metadata row shows total duration, not how many things
            // make it up), and unlike the sibling lists this one can't say
            // *what* they are: a Playlist mixes Movies and Episodes, which
            // is why this header is the vague "Items" where
            // `CollectionItemList`'s is "Movies". Uninflected past one, the
            // same shape `DownloadsView`'s "\(count) Episodes" already
            // uses.
            Text("\(items.count) Items")
                .font(.title3.bold())
                .padding(.horizontal)

            let metrics = DetailRowGridMetrics(
                containerWidth: availableWidth, isRegularWidth: horizontalSizeClass == .regular,
                artwork: .landscapeThumbnail
            )

            // A `LazyVGrid` only once there's genuinely more than one
            // column to lay out — the single-column case stays on the
            // `LazyVStack` it has always used, so compact width is
            // byte-identical to before this existed. Same split, same
            // reasoning, as `SeasonEpisodeList`'s and
            // `CollectionItemList`'s.
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
    }

    /// Shared by both branches above so the single- and multi-column
    /// lists can never drift apart in what a row actually is.
    @ViewBuilder
    private func itemRows(metrics: DetailRowGridMetrics) -> some View {
        ForEach(items) { item in
            PlaylistItemRow(
                item: item, onPlay: { onPlayItem(item.id) },
                thumbnailWidth: metrics.artworkWidth, thumbnailHeight: metrics.artworkHeight,
                client: client, userID: userID, downloadManager: downloadManager
            )
        }
    }
}

/// One playlist member — mirrors `CollectionItemList.CollectionItemRow`'s
/// two-independent-tap-targets shape (thumbnail plays this item directly;
/// title/metadata/synopsis text pushes into its own detail page via
/// `NavigationLink`, since a movie or episode inside a playlist already has
/// its own full detail page, same reasoning as a BoxSet's member row) —
/// just always landscape-shaped (the "Thumb" image, `item.thumbImageURL`,
/// falling back to the poster image cropped to fill the same 16:9 frame
/// when no Thumb exists — same fallback `LandscapeMediaCard` uses) rather
/// than switching to a poster for a Movie member the way a rail tile does
/// elsewhere in the app (`MediaItem.usesLandscapeRailTile`). Confirmed with
/// the user (2026-09-02): a uniform shape reads better in this specific
/// list than the kind-dependent split. `railTitle`/`railSubtitle` still
/// handle the metadata difference with no further branching needed here: a
/// Movie member shows its own name + "year · duration"; an Episode member
/// shows its series name + "S1:E4 · Episode Name" — exactly what
/// distinguishes rows from different shows/movies in a mixed playlist.
private struct PlaylistItemRow: View {
    let item: MediaItem
    var onPlay: () -> Void
    /// Supplied by `DetailRowGridMetrics` rather than fixed on this type —
    /// see that type for why a row in a two-column grid can't keep the
    /// same 160x90 thumbnail a full-width row uses.
    let thumbnailWidth: CGFloat
    let thumbnailHeight: CGFloat
    /// `nil` (no live session — shouldn't happen in practice on a screen
    /// that already requires one, but degrades gracefully) omits the
    /// per-item download button entirely rather than showing one that
    /// can't actually resolve `playbackInfo` — same as `EpisodeRow`'s
    /// identical trio.
    var client: JellyfinAPIClient?
    var userID: String?
    var downloadManager: DownloadManager?

    /// Measured height of the title/subtitle block above the synopsis —
    /// see `overviewLineLimit`. 0 until the first layout pass reports.
    @State private var headerHeight: CGFloat = 0

    /// Line heights of the text styles this row stacks, used by
    /// `overviewLineLimit` below. See `CollectionItemRow`'s identical pair
    /// for why these are `@ScaledMetric` rather than plain literals.
    @ScaledMetric(relativeTo: .subheadline) private var titleLineHeight: CGFloat = 20
    @ScaledMetric(relativeTo: .caption) private var captionLineHeight: CGFloat = 16

    /// How many lines of synopsis fit under the title and subtitle within
    /// `thumbnailHeight`.
    ///
    /// Derived rather than the flat `lineLimit(6)` this used to carry: six
    /// lines never came close to fitting a 16:9 thumbnail's 90pt at this
    /// row's single-column size, so the `.clipped()` below was slicing a
    /// line through its x-height on every row with a synopsis rather than
    /// letting `Text` truncate it.
    ///
    /// What's reserved is *measured* (`headerHeight`), not estimated from
    /// the title's own `lineLimit(2)`. Estimating cost two lines: nearly
    /// every title here is one line — `railTitle` is a series name for an
    /// episode member — so budgeting two reserved 60pt of a 90pt row
    /// where the header actually measures ~35pt, and showed a single
    /// line with a third of the row left empty. Measuring is also
    /// self-correcting in the direction that matters: a title that *does*
    /// wrap shrinks the synopsis by a line rather than pushing it under
    /// the clip.
    ///
    /// The fallback covers the first frame only, before
    /// `.onGeometryChange` has reported; it's the conservative estimate,
    /// so a row can only ever gain lines as it settles, never flash more
    /// than it can hold.
    ///
    /// Measured live, 2026-09-04: 3 lines at 90pt (iPhone 17, and any
    /// compact-width row), 1 at the 68pt of an iPad portrait two-column
    /// row, 3 at the 96pt of an iPad landscape one. `CollectionItemRow`
    /// deliberately still uses the flat estimate — switching it too would
    /// take its rows from 4 lines to the 6-line cap, which is a call
    /// about how much prose that page wants rather than a bug fix, and
    /// isn't part of this change.
    private var overviewLineLimit: Int {
        let reserved = headerHeight > 0
            ? headerHeight
            : titleLineHeight * 2 + captionLineHeight + 4
        return max(1, min(6, Int((thumbnailHeight - reserved - 4) / captionLineHeight)))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // A `ZStack`, not the download button nested inside the Play
            // `Button`'s own label — same reasoning as `EpisodeRow`'s
            // identical split: a button nested in another button's label
            // risks having its taps swallowed by the outer one instead of
            // reaching it. This keeps the two as independent sibling tap
            // targets layered on the same thumbnail instead.
            //
            // `.bottomTrailing`, not `.topTrailing` — the corner scheme this
            // thumbnail follows is favorite (top-left) / watched (top-right)
            // / show logo (bottom-left) / download (bottom-right), so the
            // download badge below doesn't land on top of
            // `watchStatusOverlay`'s watched-eye badge, which already owns
            // top-right.
            ZStack(alignment: .bottomTrailing) {
                Button(action: onPlay) {
                    ZStack {
                        AsyncRemoteImage(
                            url: item.thumbImageURL ?? item.primaryImageURL,
                            placeholderSystemImage: item.kind.placeholderSystemImage
                        )
                        .frame(width: thumbnailWidth, height: thumbnailHeight)
                        // Same show-logo treatment Home's own episode rail
                        // tiles use (`LandscapeMediaCard`) — self-gated to
                        // `.episode` items with a logo, so a Movie member's
                        // thumbnail is untouched. Applied before the Play
                        // button's circle+glyph below (a `ZStack` sibling, not
                        // part of this `.overlay` chain), so the logo sits
                        // bottom-left underneath it rather than competing for
                        // the same center spot.
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
                // Same treatment as `CollectionItemRow`'s identical thumbnail
                // `Button` — a plain `Button` already reads as one VoiceOver
                // element with the `.isButton` trait, so just a label is needed.
                .accessibilityLabel(String(localized: "Play \(item.railTitle)"))

                // Same component the detail page's own Play/Resume row
                // uses — full parity (idle/preparing/downloading/
                // downloaded states, audio-track prompt, subtitle
                // warning), not a slimmed-down copy. `item.episodeLabel`
                // is `nil` for a Movie member, same "bare state word"
                // fallback `EpisodeRow`'s identical call site documents.
                if let client, let userID, let downloadManager {
                    DownloadButton(
                        item: item, client: client, userID: userID, downloadManager: downloadManager, style: .overlay,
                        accessibilityContext: item.episodeLabel
                    )
                        .padding(4)
                }
            }

            // See `PosterCard.body`'s doc comment for why the
            // `NavigationLink` needs its own `ZStack` wrapper, not just
            // sitting bare inside this row's `HStack`, when this row
            // renders inside a `LazyVStack` (`PlaylistItemList` above).
            ZStack(alignment: .topLeading) {
                NavigationLink(value: AppRoute.assetDetail(itemID: item.id, preloadedItem: item)) {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            // Title and subtitle measured together as one
                            // block, so `overviewLineLimit` divides what's
                            // genuinely left rather than what a worst-case
                            // estimate assumed — see that property. Only
                            // these two: the synopsis is deliberately
                            // outside this stack, since measuring it too
                            // would make the limit depend on its own
                            // result.
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

                        // Purely decorative "this opens something" cue —
                        // same reasoning as `CollectionItemRow`'s identical
                        // chevron.
                        Image(systemName: "chevron.right")
                            .font(.caption.bold())
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Caps the text column to the thumbnail's own height,
                    // top-aligned — see `CollectionItemRow`'s identical
                    // `.frame`/`.clipped()` pair for why this (not a fixed
                    // `lineLimit` alone) is what actually enforces it.
                    .frame(height: thumbnailHeight, alignment: .top)
                    .clipped()
                    .contentShape(Rectangle())
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(item.accessibilityDescription)
                    .accessibilityAddTraits(.isButton)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
