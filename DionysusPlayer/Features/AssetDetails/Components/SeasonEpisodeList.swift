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

    /// This list's own width, fed to `DetailRowGridMetrics` below.
    ///
    /// Measured with `.onGeometryChange` rather than read from
    /// `UIScreen`/`keyWindow`: only the former is a layout dependency
    /// SwiftUI actually tracks, so the list reflows on rotation and on a
    /// Split View resize instead of staying frozen at whatever width it
    /// first saw. (`HeroHeaderView` needed exactly this fix for exactly
    /// this reason — see its `measuredWidth`.)
    ///
    /// Starts at 0, which `DetailRowGridMetrics` resolves to a single
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
                let metrics = DetailRowGridMetrics(
                    containerWidth: availableWidth, isRegularWidth: horizontalSizeClass == .regular,
                    artwork: .episodeThumbnail
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
    private func episodeRows(metrics: DetailRowGridMetrics) -> some View {
        ForEach(episodes) { episode in
            EpisodeRow(
                episode: episode,
                isCurrent: episode.id == currentEpisodeID,
                thumbnailWidth: metrics.artworkWidth,
                thumbnailHeight: metrics.artworkHeight,
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
    /// Supplied by `DetailRowGridMetrics` rather than fixed on this type —
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
                            // `DetailRowGridMetrics` now produces is ~198pt
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
