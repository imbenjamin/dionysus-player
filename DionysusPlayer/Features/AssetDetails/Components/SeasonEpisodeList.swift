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
    @State private var episodes: [MediaItem] = []
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Episodes")
                    .font(.title3.bold())

                Spacer()

                if seasons.count > 1 {
                    Picker("Season", selection: $selectedSeasonID) {
                        ForEach(seasons) { season in
                            Text(season.name).tag(Optional(season.id))
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            .padding(.horizontal)

            if isLoading {
                LoadingView().frame(height: 120)
            } else {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(episodes) { episode in
                        EpisodeRow(
                            episode: episode,
                            isCurrent: episode.id == currentEpisodeID,
                            onPlay: { onPlayEpisode(episode.id) },
                            onSelect: { onSelectEpisode(episode.id) }
                        )
                    }
                }
                .padding(.horizontal)
            }
        }
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

    private func loadEpisodes(showsLoadingIndicator: Bool = true) async {
        guard let seasonID = selectedSeasonID,
              let client = appState.apiClient,
              let userID = appState.currentUser?.id else { return }

        if showsLoadingIndicator { isLoading = true }
        defer { isLoading = false }
        do {
            let images = await client.makeImageURLBuilder()
            let result = try await client.episodes(seriesID: seriesID, seasonID: seasonID, userID: userID)
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
    var onPlay: () -> Void
    var onSelect: () -> Void

    private static let thumbnailWidth: CGFloat = 160
    private static let thumbnailHeight: CGFloat = 90

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // A thin accent bar rather than a full-row background/inset —
            // keeps every other row's layout pixel-identical to before
            // this existed, rather than only the highlighted row shifting.
            RoundedRectangle(cornerRadius: 2)
                .fill(isCurrent ? Color.dionysusPrimary : .clear)
                .frame(width: 3)

            Button(action: onPlay) {
                ZStack {
                    AsyncRemoteImage(url: episode.imageURL(type: "Primary", maxWidth: 300))
                        .frame(width: Self.thumbnailWidth, height: Self.thumbnailHeight)
                        // Same progress-bar treatment as `PosterCard`'s rail
                        // thumbnails (`watchStatusOverlay`) — this can show
                        // up alongside the main Play/Resume button's own
                        // progress bar when this row's episode is also the
                        // page's current content; a deliberate, harmless
                        // overlap rather than something worth suppressing.
                        .overlay(alignment: .bottom) {
                            if let fraction = episode.playedFraction, fraction > 0, !episode.isPlayed {
                                ProgressView(value: fraction)
                                    .tint(.dionysusHighlight)
                                    .padding(.horizontal, 4)
                                    .padding(.bottom, 4)
                            }
                        }
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

            Button(action: onSelect) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(episode.episodeLabel.map { "\($0)  \(episode.name)" } ?? episode.name)
                            .font(.subheadline.bold())
                            .foregroundStyle(isCurrent ? Color.dionysusPrimary : .primary)
                            .lineLimit(2)

                        if let duration = episode.durationText {
                            Text(duration)
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
