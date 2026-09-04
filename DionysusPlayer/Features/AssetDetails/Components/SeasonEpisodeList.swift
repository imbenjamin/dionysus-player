import SwiftUI

/// Season picker (when there's more than one) plus that season's episode
/// list, for `ShowDetailView`.
struct SeasonEpisodeList: View {
    let seriesID: String
    let seasons: [MediaItem]
    @Binding var selectedSeasonID: String?
    /// `AssetDetailViewModel.episodeListRefreshToken` — a new value each
    /// time forces `loadEpisodes()` to re-run even though `selectedSeasonID`
    /// itself hasn't changed, which is what keeps a just-played episode's
    /// row (its own progress bar/watched state — see `EpisodeRow`) from
    /// sitting stale after returning from the player. See that property's
    /// own doc comment for why it's driven from there rather than this view
    /// re-fetching on some timer/lifecycle event of its own.
    var refreshToken: UUID
    /// The episode currently being displayed as this page's own content
    /// (`ShowDetailView`'s episode-content case — see that view's doc
    /// comment), if any — highlighted in the list below so it's clear which
    /// row the rest of the page is about. `nil` for ordinary Show/Season
    /// browsing, where no single episode is "the" content.
    var currentEpisodeID: String?
    /// Plays that episode directly (the thumbnail's own play button) —
    /// distinct from `onSelectEpisode` below, which changes what this page
    /// *shows* without opening the player at all.
    var onPlayEpisode: (String) -> Void
    /// Switches the detail page's own content (hero/synopsis/Play button/
    /// tabs) to that episode in place, via
    /// `AssetDetailViewModel.selectEpisode(_:)` — tapping a row's title/
    /// overview text, as opposed to its thumbnail (`onPlayEpisode` above).
    var onSelectEpisode: (String) -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var episodes: [MediaItem] = []
    @State private var isLoading = false

    /// This list's own width, fed to `EpisodeGridMetrics` below.
    ///
    /// Measured with `.onGeometryChange` rather than read from
    /// `UIScreen`/`keyWindow`: only the former is a layout dependency
    /// SwiftUI actually tracks, so the list reflows on rotation and on a
    /// Split View resize instead of staying frozen at whatever width it
    /// first saw. (`HeroHeaderView` needed exactly this fix for exactly
    /// this reason — see its `measuredWidth`.)
    ///
    /// Starts at 0, which `EpisodeGridMetrics` resolves to a single
    /// column — the layout this list has always had — so the first frame
    /// can never be a wrong-width grid that then reflows. In practice
    /// even that frame isn't visible: `isLoading` starts true, so the
    /// measurement lands while `LoadingView` is showing, well before any
    /// row exists.
    @State private var availableWidth: CGFloat = 0

    /// Backs `pickerWidth` below — `@ScaledMetric` tracks Dynamic Type the
    /// same way the trigger `Text`'s own (ambient, `.body`-style) font does,
    /// so the frame grows/shrinks in step with the text it's sized for
    /// instead of being tuned for one specific size.
    @ScaledMetric(relativeTo: .body) private var scaledPickerWidth: CGFloat = 160

    /// The season menu trigger's fixed frame width — see the `Menu` label
    /// below for why this has to stay a fixed width, not `maxWidth`.
    /// Capped rather than left to scale all the way to the largest
    /// accessibility sizes unbounded: this trigger shares a row with the
    /// "Episodes" title and `SeasonDownloadButton`, and an uncapped value at
    /// the top accessibility sizes would exceed the width of the smallest
    /// supported phone screen (SE, 375pt) on its own. Still meaningfully
    /// wider than the old hardcoded 160pt below that ceiling — see
    /// `selectedSeasonName`'s doc comment for the matching character-budget
    /// scale this drives.
    private var pickerWidth: CGFloat { min(scaledPickerWidth, 200) }

    /// The season menu's own trigger label — falls back to the first
    /// season's name if `selectedSeasonID` doesn't (yet) match any of
    /// `seasons`, so the trigger never renders blank. Truncated here in
    /// plain Swift, not left to `Text`'s own `.lineLimit`/`.truncationMode`
    /// — see the `Menu` label below for why. `maxLength` was a flat 16
    /// before, tuned for one specific (160pt) frame width — at larger
    /// Dynamic Type sizes that could still overflow the frame (each
    /// character renders wider), and at smaller sizes it truncated more
    /// than the frame actually needed. Scaling it by the same ratio
    /// `pickerWidth` itself scales by keeps the two in step, however either
    /// one changes, rather than two independently hand-tuned numbers
    /// drifting apart.
    private var selectedSeasonName: String {
        let name = seasons.first { $0.id == selectedSeasonID }?.name ?? seasons.first?.name ?? ""
        let maxLength = max(4, Int((16 * pickerWidth / 160).rounded()))
        guard name.count > maxLength else { return name }
        return String(name.prefix(maxLength)) + "\u{2026}"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Episodes")
                    .font(.title3.bold())
                    // Never the one to give up space — a long season name
                    // is what needs to shrink below, not this fixed title.
                    .layoutPriority(1)

                Spacer()

                if seasons.count > 1 {
                    // A hand-built `Menu`, not `Picker(...).pickerStyle(.menu)`
                    // — a menu-style `Picker`'s truncation/sizing is
                    // unreliable for a long trigger label (`.lineLimit(1)`
                    // doesn't reliably reach it), so this builds the
                    // trigger's `Text` directly to guarantee `.lineLimit`/
                    // `.truncationMode` actually apply. Pre-truncating the
                    // string itself (`selectedSeasonName`, above) rather
                    // than trusting `Text`'s own truncation, `.id()`-resetting
                    // that `Text`'s identity per season, and using a fixed
                    // (not `maxWidth`) frame below are all the same fix for
                    // the same underlying quirk: this trigger's layout
                    // doesn't reliably recompute in place when only its
                    // string content changes.
                    Menu {
                        ForEach(seasons) { season in
                            Button(season.name) { selectedSeasonID = season.id }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(selectedSeasonName)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .id(selectedSeasonID)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                        }
                    }
                    .frame(width: pickerWidth, alignment: .trailing)
                }

                // Next to the picker when there's one to show; in its place
                // (still trailing the "Episodes" title) for a single-season
                // show, where the picker itself is omitted above.
                if let client = appState.apiClient,
                   let userID = appState.currentUser?.id ?? appState.sessionStore.credentials?.userID,
                   let selectedSeasonID {
                    SeasonDownloadButton(
                        seriesID: seriesID, seasonID: selectedSeasonID, episodes: episodes,
                        client: client, userID: userID, downloadManager: appState.downloadManager
                    )
                    .layoutPriority(1)
                }
            }
            .padding(.horizontal)

            if isLoading {
                LoadingView().frame(height: 120)
            } else {
                let metrics = EpisodeGridMetrics(
                    containerWidth: availableWidth, isRegularWidth: horizontalSizeClass == .regular
                )

                // A `LazyVGrid` only once there's genuinely more than one
                // column to lay out — the single-column case stays on the
                // `LazyVStack` it has always used, so compact width is
                // byte-identical to before this existed rather than
                // routed through a one-column grid that merely ought to
                // behave the same. It also sidesteps handing
                // `GridItem(.fixed(_:))` the zero width that
                // `availableWidth` starts at.
                if metrics.columnCount > 1 {
                    LazyVGrid(columns: metrics.columns, alignment: .leading, spacing: 16) {
                        episodeRows(metrics: metrics)
                    }
                    .padding(.horizontal)
                } else {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        episodeRows(metrics: metrics)
                    }
                    .padding(.horizontal)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        .task(id: selectedSeasonID) { await loadEpisodes() }
        // Separate from the `.task(id:)` above rather than folded into one
        // combined id: `selectedSeasonID` changing should show the loading
        // spinner (a real season switch — nothing to show yet), but
        // `refreshToken` changing shouldn't — it's a silent background
        // refresh of a season the user is already looking at, and swapping
        // to `LoadingView` every time someone returns from playback would
        // be a jarring flash for what's meant to be invisible.
        .onChange(of: refreshToken) { _, _ in Task { await loadEpisodes(showsLoadingIndicator: false) } }
    }

    /// Shared by both branches above so the single- and multi-column
    /// lists can never drift apart in what a row actually is.
    @ViewBuilder
    private func episodeRows(metrics: EpisodeGridMetrics) -> some View {
        ForEach(episodes) { episode in
            EpisodeRow(
                episode: episode,
                isCurrent: episode.id == currentEpisodeID,
                thumbnailWidth: metrics.thumbnailWidth,
                thumbnailHeight: metrics.thumbnailHeight,
                onPlay: { onPlayEpisode(episode.id) },
                onSelect: { onSelectEpisode(episode.id) },
                client: appState.apiClient,
                userID: appState.currentUser?.id ?? appState.sessionStore.credentials?.userID,
                downloadManager: appState.downloadManager
            )
        }
    }

    private func loadEpisodes(showsLoadingIndicator: Bool = true) async {
        guard let seasonID = selectedSeasonID,
              let client = appState.apiClient,
              let userID = appState.currentUser?.id ?? appState.sessionStore.credentials?.userID else { return }

        if showsLoadingIndicator { isLoading = true }
        defer { isLoading = false }
        do {
            let images = await client.makeImageURLBuilder()
            // `detailFields`, not the plain default — this array is also
            // what `DownloadButton`/`SeasonDownloadButton` enqueue directly
            // (see `JellyfinAPIClient.episodes(...)`'s own doc comment):
            // without `People` here, an episode download's offline Cast &
            // Crew tab silently had nothing to show, unlike a movie's.
            let result = try await client.episodes(seriesID: seriesID, seasonID: seasonID, userID: userID, fields: JellyfinAPIClient.detailFields)
            episodes = result.items.map { MediaItem(dto: $0, images: images) }
        } catch {
            episodes = []
        }
    }
}

/// Two independent tap targets, side by side rather than one nested inside
/// the other (a button nested in another button's label risks having its
/// taps swallowed by the outer one instead of reaching it — same reasoning
/// `PosterCard`'s old episode-menu button followed): the thumbnail plays
/// this episode directly, the title/overview text switches the detail
/// page's own content to it. See `SeasonEpisodeList.onPlayEpisode`/
/// `onSelectEpisode`'s doc comments for the distinction.
private struct EpisodeRow: View {
    let episode: MediaItem
    /// True for the episode `ShowDetailView` is currently showing as its own
    /// content (see `SeasonEpisodeList.currentEpisodeID`'s doc comment) —
    /// otherwise identical to any other row, just with a highlight so it's
    /// clear which one the rest of the page is about.
    var isCurrent: Bool = false
    /// Supplied by `EpisodeGridMetrics` rather than fixed on this type —
    /// see that type for why a row in a two-column grid can't keep the
    /// same 160x90 thumbnail a full-width row uses.
    let thumbnailWidth: CGFloat
    let thumbnailHeight: CGFloat
    var onPlay: () -> Void
    var onSelect: () -> Void
    /// `nil` (no live session — shouldn't happen in practice on a screen
    /// that already requires one, but degrades gracefully) omits the
    /// per-episode download button entirely rather than showing one that
    /// can't actually resolve `playbackInfo`.
    var client: JellyfinAPIClient?
    var userID: String?
    var downloadManager: DownloadManager?

    /// Air date and runtime together, e.g. "1 Aug 2026 · 42m" — see
    /// `MediaItem.episodeAirDateText`'s doc comment for why a row here
    /// shows the exact date rather than just the coarser year `yearText`
    /// gives a show or season.
    private var episodeMetaText: String? {
        let parts = [episode.episodeAirDateText, episode.durationText].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    /// Same content as `episodeMetaText`, worded for VoiceOver — see
    /// `MediaItem.durationAccessibilityText`'s doc comment for why the
    /// duration half needs this.
    private var episodeMetaAccessibilityText: String? {
        let parts = [episode.episodeAirDateText, episode.durationAccessibilityText].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// The thumbnail's own play/resume button — bare SF Symbols otherwise
    /// leave VoiceOver nothing to read but "Progress 20%, button" (the
    /// progress bar's own default value) for a part-watched episode, or
    /// "Play, button" (the `play.fill` symbol's own default name) for an
    /// unwatched one — neither says *which* episode. Mirrors
    /// `PlayResumeButtonRow.buttonTitle`'s own Play/Resume wording, plus
    /// the resume position for a part-watched episode specifically, since
    /// this row has no separate progress-bar label of its own the way the
    /// main detail page's row does.
    private var thumbnailAccessibilityLabel: String {
        let label = episode.episodeLabel ?? episode.name
        if let fraction = episode.playedFraction, fraction > 0, !episode.isPlayed,
           let resumeText = episode.resumePositionAccessibilityText {
            return String(localized: "Resume \(label) from \(resumeText)")
        }
        return String(localized: "Play \(label)")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // A thin accent bar rather than a full-row background/inset —
            // keeps every other row's layout pixel-identical to before
            // this existed, rather than only the highlighted row shifting.
            RoundedRectangle(cornerRadius: 2)
                .fill(isCurrent ? Color.dionysusPrimary : .clear)
                .frame(width: 3)

            // A `ZStack`, not the download button nested inside the Play
            // `Button`'s own label — a button nested in another button's
            // label risks having its taps swallowed by the outer one
            // instead of reaching it (see this type's own doc comment on
            // why the thumbnail/title-row split above already avoids
            // that); this keeps the two as independent sibling tap targets
            // layered on the same thumbnail instead.
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
                            // 400, not the 300 this asked for while the
                            // thumbnail was fixed at 160pt: the widest
                            // `EpisodeGridMetrics` now produces is ~198pt
                            // (a 13-inch iPad in landscape), which needs
                            // 400px at 2x. The old value was already a
                            // little short of even 160pt's 320px.
                            url: episode.imageURL(type: "Primary", maxWidth: 400),
                            placeholderSystemImage: "play.tv"
                        )
                            .frame(width: thumbnailWidth, height: thumbnailHeight)
                            // Same favorite/watched/progress-bar treatment as
                            // `PosterCard`'s rail thumbnails — this row used
                            // to hand-duplicate just the progress-bar part
                            // (and only that part), leaving this page's
                            // episode thumbnails with no favorite/watched
                            // badge at all. The progress bar can still show
                            // up alongside the main Play/Resume button's own
                            // progress bar when this row's episode is also
                            // the page's current content; a deliberate,
                            // harmless overlap rather than something worth
                            // suppressing.
                            .watchStatusOverlay(for: episode)
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
                .accessibilityLabel(thumbnailAccessibilityLabel)

                // Same component the detail page's own Play/Resume row
                // uses — full parity (idle/preparing/downloading/
                // downloaded states, audio-track prompt, subtitle
                // warning), not a slimmed-down copy.
                if let client, let userID, let downloadManager {
                    DownloadButton(
                        item: episode, client: client, userID: userID, downloadManager: downloadManager, style: .overlay,
                        accessibilityContext: episode.episodeLabel
                    )
                        .padding(4)
                }
            }

            Button(action: onSelect) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(episode.episodeLabel.map { "\($0)  \(episode.name)" } ?? episode.name)
                            .font(.subheadline.bold())
                            .foregroundStyle(isCurrent ? Color.dionysusPrimary : .primary)
                            .lineLimit(2)

                        if let meta = episodeMetaText {
                            Text(meta)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(episodeMetaAccessibilityText ?? meta)
                        }

                        if let overview = episode.overview {
                            Text(overview)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }

                    Spacer(minLength: 0)

                    // The standard iOS "this row does something when
                    // tapped" cue (Settings, Podcasts, Music, ...) — reads
                    // as "select/switch to this" rather than committing to
                    // "this pushes a new screen" the way a `NavigationLink`
                    // chevron usually implies, which fits: tapping updates
                    // this page's own content in place rather than
                    // navigating away from it.
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// Column count, per-row width and thumbnail size for the episode list,
/// derived from the width actually available to it.
///
/// ## Why the list isn't one column everywhere
///
/// A single full-width row wastes most of the width it's given on iPad.
/// Measured on an 11-inch iPad (Brooklyn Nine-Nine, season 1): each row's
/// text block ran 601pt in portrait and 961pt in landscape while staying
/// 71pt tall, so the overview truncated after two lines of ~160
/// characters and the trailing chevron ended up ~1,150pt from the
/// thumbnail it belongs to. The thumbnail meanwhile stayed at a fixed
/// 160x90, so the row read as a small picture with a very long strip of
/// text beside it rather than as one object.
///
/// Two columns fix the measure without shrinking the list's own footprint
/// — unlike the metadata column above it (`ReadableDetailColumn`), which
/// is capped instead. The distinction is what the extra width is *for*: a
/// paragraph gains nothing from it, a list of items gains another item.
/// It also halves the scroll depth of a 20-plus-episode season.
///
/// ## Why the thumbnail scales
///
/// The row's fixed 160pt thumbnail is 187pt of a row once the accent bar
/// and spacing are counted, which a full-width row absorbs easily and a
/// 386pt half-width row does not — it would leave 199pt of text, about 38
/// characters at `.caption`, tighter than the single-column layout this
/// is meant to improve on. Sizing the thumbnail from the row it sits in
/// (the same approach `PosterGridMetrics` takes for poster grids) keeps
/// the text at a workable measure at every width:
///
/// | container | columns | row | thumbnail | text |
/// | --- | --- | --- | --- | --- |
/// | iPhone portrait, 402pt | 1 | 370pt | 160x90 | 183pt |
/// | iPhone Pro Max landscape, 932pt | 2 | 442pt | 133x75 | 282pt |
/// | iPad portrait, 820pt | 2 | 386pt | 120x68 | 239pt |
/// | iPad landscape, 1180pt | 2 | 566pt | 170x96 | 369pt |
///
/// `rowWidth` is what each column *will* be given, solved rather than
/// read back from the grid — see `columns` for why the grid can't be
/// asked, and what goes wrong if it is.
///
/// The single-column case deliberately keeps the established 160x90
/// rather than deriving from `thumbnailWidthFraction` like the rest —
/// which is to say compact width renders exactly as it did before this
/// type existed. The fraction would give an iPhone portrait row 111pt and
/// shrink a layout that has no width problem to solve.
struct EpisodeGridMetrics {
    /// Both the gap between columns and, via `SeasonEpisodeList`'s own
    /// `.padding(.horizontal)`, the list's outer margin.
    static let spacing: CGFloat = 16
    static let horizontalPadding: CGFloat = 16

    /// A second column has to be worth having. Below this a row can't
    /// hold a thumbnail plus enough text to beat the full-width layout,
    /// so the list stays single-column however wide the container claims
    /// to be — which is also what a zero `containerWidth` (the first
    /// frame, before `.onGeometryChange` reports) resolves to.
    static let minimumRowWidth: CGFloat = 320

    /// See this type's doc comment on why single-column keeps this rather
    /// than deriving its thumbnail like every other case.
    static let singleColumnThumbnailWidth: CGFloat = 160

    static let thumbnailWidthFraction: CGFloat = 0.3
    /// Clamps either side of `thumbnailWidthFraction`: the floor keeps a
    /// narrow two-column row's thumbnail recognisable, the ceiling stops
    /// a 13-inch iPad in landscape from turning it into a poster.
    static let minimumThumbnailWidth: CGFloat = 120
    static let maximumThumbnailWidth: CGFloat = 200

    let columnCount: Int
    let rowWidth: CGFloat
    let thumbnailWidth: CGFloat

    /// 16:9, matching the source thumbnails and the 160x90 this row has
    /// always used.
    var thumbnailHeight: CGFloat { (thumbnailWidth * 9 / 16).rounded() }

    /// `.flexible`, **not** `.fixed` — despite `rowWidth` already being
    /// solved to fill the container exactly, and despite
    /// `PosterGridMetrics` using `.fixed` for the same job.
    ///
    /// The difference is where the width comes from. `PosterGridMetrics`'
    /// callers read it from a `GeometryReader` wrapped *around* their
    /// `ScrollView`, so it can't be affected by what the grid then does
    /// with it. This list has no such vantage point — it's one child
    /// among many inside `ShowDetailView`'s scroll content — so it
    /// measures itself, and `.fixed` closes that into a loop: fixed
    /// columns give the grid a hard minimum width, the grid raises its
    /// container to meet it, and the container is what gets measured.
    ///
    /// Observed live (iPad, 2026-09-04): rotating landscape -> portrait
    /// left the page stuck at 1180pt inside an 820pt window — hero and
    /// episode list still landscape-width and shifted 180pt off the
    /// leading edge, permanently, because the 2 x 566pt grid kept
    /// re-asserting the width that had produced it. `.flexible` has no
    /// meaningful minimum, so the measurement stays honest and the grid
    /// divides whatever it is actually given — which, for two columns,
    /// is `rowWidth` regardless.
    ///
    /// That leaves `rowWidth` sizing only `EpisodeRow`'s thumbnail, where
    /// being one frame late during a rotation is invisible.
    var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: Self.spacing, alignment: .top),
            count: columnCount
        )
    }

    /// Gated on horizontal size class *as well as* measured width, matching
    /// `ReadableDetailColumn` rather than width alone: an iPhone Pro Max in
    /// landscape is regular width and comfortably fits two columns, but a
    /// compact-width container that happens to be wide (a narrow Split View
    /// pane) is one the system is already treating as a phone.
    init(containerWidth: CGFloat, isRegularWidth: Bool) {
        let available = max(containerWidth - Self.horizontalPadding * 2, 0)
        let fitsTwoColumns = available >= Self.minimumRowWidth * 2 + Self.spacing
        columnCount = isRegularWidth && fitsTwoColumns ? 2 : 1
        rowWidth = (available - Self.spacing * CGFloat(columnCount - 1)) / CGFloat(columnCount)
        thumbnailWidth = columnCount == 1
            ? Self.singleColumnThumbnailWidth
            : min(
                max((rowWidth * Self.thumbnailWidthFraction).rounded(), Self.minimumThumbnailWidth),
                Self.maximumThumbnailWidth
            )
    }
}
