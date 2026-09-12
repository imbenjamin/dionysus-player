import SwiftUI

/// Season picker (when there's more than one) plus that season's episode
/// list, for `ShowDetailView`.
struct SeasonEpisodeList: View {
    let seriesID: String
    let seasons: [MediaItem]
    @Binding var selectedSeasonID: String?
    /// `AssetDetailViewModel.episodeListRefreshToken`: a new value re-runs
    /// `loadEpisodes()` even though `selectedSeasonID` hasn't changed, so a
    /// just-played episode's progress bar and watched state aren't stale after
    /// returning from the player. See that property for why it's driven from
    /// there rather than from a lifecycle event here.
    var refreshToken: UUID
    /// The episode this page is currently showing as its content
    /// (`ShowDetailView`'s episode-content case), highlighted in the list so
    /// it's clear which row the page is about. `nil` for Show/Season browsing.
    var currentEpisodeID: String?
    /// Plays that episode directly, from the thumbnail's play button. Distinct
    /// from `onSelectEpisode`, which changes what the page shows without
    /// opening the player.
    var onPlayEpisode: (String) -> Void
    /// Switches the page's hero/synopsis/Play button/tabs to that episode in
    /// place via `AssetDetailViewModel.selectEpisode(_:)`. Triggered by tapping
    /// a row's text rather than its thumbnail.
    var onSelectEpisode: (String) -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var episodes: [MediaItem] = []
    @State private var isLoading = false

    /// This list's width, fed to `DetailRowGridMetrics` below.
    ///
    /// Measured with `.onGeometryChange` rather than read off the window: only
    /// the former is a layout dependency SwiftUI tracks, so the list reflows on
    /// rotation and Split View resize instead of freezing at its first width
    /// (see `HeroHeaderView.measuredWidth`).
    ///
    /// Starts at 0, which `DetailRowGridMetrics` resolves to one column, so the
    /// first frame can't be a wrong-width grid that then reflows. In practice
    /// it isn't visible either: `isLoading` starts true, so the measurement
    /// lands while `LoadingView` shows.
    @State private var availableWidth: CGFloat = 0

    /// Backs `pickerWidth`. `@ScaledMetric` tracks Dynamic Type the way the
    /// trigger `Text`'s ambient `.body` font does, so the frame scales with the
    /// text it's sized for.
    @ScaledMetric(relativeTo: .body) private var scaledPickerWidth: CGFloat = 160

    /// The season menu trigger's fixed frame width — see the `Menu` label below
    /// for why it must be fixed rather than `maxWidth`. Capped because the
    /// trigger shares a row with the "Episodes" title and
    /// `SeasonDownloadButton`, and an uncapped value at the top accessibility
    /// sizes would exceed a 375pt phone screen on its own.
    /// `selectedSeasonName` scales its character budget to match.
    private var pickerWidth: CGFloat { min(scaledPickerWidth, 200) }

    /// The season menu's trigger label, falling back to the first season's name
    /// when `selectedSeasonID` doesn't yet match any of `seasons`, so it never
    /// renders blank. Truncated in Swift rather than by `Text`'s
    /// `.lineLimit`/`.truncationMode` — see the `Menu` label below.
    ///
    /// `maxLength` scales by the same ratio as `pickerWidth` rather than being a
    /// flat 16 tuned for one 160pt frame, which overflowed at larger Dynamic
    /// Type sizes and truncated more than necessary at smaller ones.
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
                    // A long season name shrinks below; this fixed title doesn't.
                    .layoutPriority(1)

                Spacer()

                if seasons.count > 1 {
                    // A hand-built `Menu`, not `Picker(...).pickerStyle(.menu)`:
                    // a menu-style `Picker`'s `.lineLimit(1)` doesn't reliably
                    // reach its trigger label, so this builds the `Text`
                    // directly.
                    //
                    // Pre-truncating the string (`selectedSeasonName`),
                    // `.id()`-resetting the `Text` per season, and the fixed
                    // (not `maxWidth`) frame below all work around one quirk:
                    // this trigger's layout doesn't reliably recompute in place
                    // when only its string content changes.
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

                // Next to the picker when there is one; in its place, still
                // trailing the "Episodes" title, for a single-season show.
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
                    artwork: .landscapeThumbnail
                )

                // A `LazyVGrid` only when there's more than one column; the
                // single-column case stays on a `LazyVStack` rather than a
                // one-column grid that merely ought to behave the same. It also
                // avoids handing `GridItem(.fixed(_:))` the zero width
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
        // Separate from the `.task(id:)` above rather than one combined id: a
        // `selectedSeasonID` change should show the spinner, having nothing to
        // display yet, while a `refreshToken` change is a silent refresh of a
        // season already on screen and shouldn't flash `LoadingView` every time
        // the user returns from playback.
        .onChange(of: refreshToken) { _, _ in Task { await loadEpisodes(showsLoadingIndicator: false) } }
    }

    /// Shared by both branches above so the single- and multi-column lists
    /// can't drift apart.
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
            // `detailFields`, not the default: this array is what
            // `DownloadButton`/`SeasonDownloadButton` enqueue directly (see
            // `JellyfinAPIClient.episodes(...)`), and without `People` an
            // episode download's offline Cast & Crew tab had nothing to show.
            let result = try await client.episodes(seriesID: seriesID, seasonID: seasonID, userID: userID, fields: JellyfinAPIClient.detailFields)
            episodes = result.items.map { MediaItem(dto: $0, images: images) }
        } catch {
            episodes = []
        }
    }
}

/// Two independent tap targets side by side rather than nested, since a button
/// inside another button's label risks its taps being swallowed: the thumbnail
/// plays the episode, the text switches the page's content to it. See
/// `SeasonEpisodeList.onPlayEpisode`/`onSelectEpisode`.
private struct EpisodeRow: View {
    let episode: MediaItem
    /// True for the episode `ShowDetailView` is showing as its content (see
    /// `SeasonEpisodeList.currentEpisodeID`). Only adds a highlight; the row is
    /// otherwise identical.
    var isCurrent: Bool = false
    /// Supplied by `DetailRowGridMetrics` rather than fixed here — see that type
    /// for why a two-column row can't keep a full-width row's 160x90 thumbnail.
    let thumbnailWidth: CGFloat
    let thumbnailHeight: CGFloat
    var onPlay: () -> Void
    var onSelect: () -> Void
    /// `nil` (no live session) omits the download button rather than showing one
    /// that can't resolve `playbackInfo`.
    var client: JellyfinAPIClient?
    var userID: String?
    var downloadManager: DownloadManager?

    /// Air date and runtime, e.g. "1 Aug 2026 · 42m" — see
    /// `MediaItem.episodeAirDateText` for why an episode row shows the exact
    /// date rather than the year a show or season gets.
    private var episodeMetaText: String? {
        let parts = [episode.episodeAirDateText, episode.durationText].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    /// `episodeMetaText` worded for VoiceOver — see
    /// `MediaItem.durationAccessibilityText` for why the duration half needs it.
    private var episodeMetaAccessibilityText: String? {
        let parts = [episode.episodeAirDateText, episode.durationAccessibilityText].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// The thumbnail's play/resume button. Without this, VoiceOver reads
    /// "Progress 20%, button" or "Play, button" from the symbols' own defaults,
    /// neither of which says which episode. Mirrors
    /// `PlayResumeButtonRow.buttonTitle`'s wording, plus the resume position,
    /// since this row has no separate progress-bar label.
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
            // A thin accent bar rather than a full-row background or inset, so
            // the highlighted row's layout matches every other row's.
            RoundedRectangle(cornerRadius: 2)
                .fill(isCurrent ? Color.dionysusPrimary : .clear)
                .frame(width: 3)

            // A `ZStack`, not the download button inside the Play `Button`'s
            // label: a nested button risks its taps being swallowed by the
            // outer one, the same reason this type splits the thumbnail from the
            // title row.
            //
            // `.bottomTrailing` because this thumbnail's corner scheme is
            // favorite (top-left) / watched (top-right) / show logo
            // (bottom-left) / download (bottom-right), and `watchStatusOverlay`
            // already owns top-right.
            ZStack(alignment: .bottomTrailing) {
                Button(action: onPlay) {
                    ZStack {
                        AsyncRemoteImage(
                            // 400px: the widest `DetailRowGridMetrics` produces
                            // is ~198pt (13-inch iPad, landscape), needing 400px
                            // at 2x. 300 was short even of 160pt's 320px.
                            url: episode.imageURL(type: "Primary", maxWidth: 400),
                            placeholderSystemImage: "play.tv"
                        )
                            .frame(width: thumbnailWidth, height: thumbnailHeight)
                            // The same favorite/watched/progress-bar treatment as
                            // `PosterCard`'s rail thumbnails. This row's progress
                            // bar can appear alongside the main Play/Resume
                            // button's when its episode is also the page's
                            // content — a harmless overlap, left as is.
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

                // The same component the detail page's Play/Resume row uses, at
                // full parity, not a slimmed-down copy.
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

                    // The standard iOS "this row does something when tapped"
                    // cue, which reads as "switch to this" rather than the push
                    // a `NavigationLink` chevron implies — tapping updates this
                    // page in place rather than navigating away.
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(A11yID.AssetDetail.episodeRow(episode.id))
        }
    }
}
