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

    /// The season menu's own trigger label — falls back to the first
    /// season's name if `selectedSeasonID` doesn't (yet) match any of
    /// `seasons`, so the trigger never renders blank. Truncated here in
    /// plain Swift, not left to `Text`'s own `.lineLimit`/`.truncationMode`:
    /// confirmed live (2026-08-19), even with a fixed-width container *and*
    /// a hard `.id()` identity reset on the `Text` (both already tried),
    /// switching to a longer name still visibly rendered an incorrectly
    /// short truncation ("Johto Journ…" instead of "The Johto Journ…") for
    /// one frame before correcting itself — `Text`'s own glyph-level
    /// truncation math has some one-frame lag recomputing against a new
    /// string in this exact position (inside a `Menu` label) that neither
    /// fix reached. Handing it an already-short string sidesteps the bug
    /// entirely: there's no truncation decision left for `Text` to get
    /// wrong, just a fixed string to draw. `maxLength` is picked to
    /// comfortably clear the 160pt trigger width at this font size — see
    /// that `.frame`'s own doc comment.
    private var selectedSeasonName: String {
        let name = seasons.first { $0.id == selectedSeasonID }?.name ?? seasons.first?.name ?? ""
        let maxLength = 16
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
                    // — confirmed live (2026-08-19) that `.lineLimit(1)`
                    // applied to a menu-style `Picker` doesn't reach its
                    // trigger label at all (a long season name like "The
                    // Johto Journeys" still wrapped to two lines even with
                    // it set, just no longer tall enough to overlap the
                    // episode list below once `.frame(maxWidth:)` capped
                    // the width — an improvement over the original bug, but
                    // not the single truncated line this needs). Building
                    // the trigger's `Text` directly guarantees `.lineLimit`/
                    // `.truncationMode` actually apply, since there's no
                    // system-provided label in between to lose them.
                    Menu {
                        ForEach(seasons) { season in
                            Button(season.name) { selectedSeasonID = season.id }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(selectedSeasonName)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                // A hard identity reset, not just a content
                                // change — confirmed live (2026-08-19): even
                                // with the fixed-width frame below (which
                                // fixed the container popping to a different
                                // *size*), switching to a longer name still
                                // visibly rendered a wrong, truncated-too-early
                                // string ("Johto Journ…" instead of "The
                                // Johto Journ…") for a frame before
                                // correcting — `Text`'s own truncation
                                // recalculation lagged one render behind the
                                // string it was handed. Forcing a fresh view
                                // identity per season means there's no
                                // existing `Text` instance left for that
                                // stale truncation state to carry over on.
                                .id(selectedSeasonID)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                        }
                    }
                    // A fixed `width`, not `maxWidth` — confirmed live
                    // (2026-08-19): with `maxWidth`, this box's own laid-out
                    // width tracked whichever season name was showing (a
                    // short one like "Specials" narrower than a long one
                    // like "The Johto Journeys"), so switching between them
                    // visibly popped through the old, narrower width/position
                    // for a frame before settling on the new one — the same
                    // "no shared fixed frame across states" glitch class as
                    // `DownloadButton`'s badge (see that view's own doc
                    // comment). A fixed width means only this `Text`'s
                    // *content* changes on selection, never this container's
                    // size, so there's nothing left to visibly resize.
                    .frame(width: 160, alignment: .trailing)
                }

                // Next to the picker when there's one to show; in its place
                // (still trailing the "Episodes" title) for a single-season
                // show, where the picker itself is omitted above.
                if let client = appState.apiClient, let userID = appState.currentUser?.id, let selectedSeasonID {
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
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(episodes) { episode in
                        EpisodeRow(
                            episode: episode,
                            isCurrent: episode.id == currentEpisodeID,
                            onPlay: { onPlayEpisode(episode.id) },
                            onSelect: { onSelectEpisode(episode.id) },
                            client: appState.apiClient,
                            userID: appState.currentUser?.id,
                            downloadManager: appState.downloadManager
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
    /// `nil` (no live session — shouldn't happen in practice on a screen
    /// that already requires one, but degrades gracefully) omits the
    /// per-episode download button entirely rather than showing one that
    /// can't actually resolve `playbackInfo`.
    var client: JellyfinAPIClient?
    var userID: String?
    var downloadManager: DownloadManager?

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

            // A `ZStack`, not the download button nested inside the Play
            // `Button`'s own label — a button nested in another button's
            // label risks having its taps swallowed by the outer one
            // instead of reaching it (see this type's own doc comment on
            // why the thumbnail/title-row split above already avoids
            // that); this keeps the two as independent sibling tap targets
            // layered on the same thumbnail instead.
            ZStack(alignment: .topTrailing) {
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

                // Same component the detail page's own Play/Resume row
                // uses — full parity (idle/preparing/downloading/
                // downloaded states, audio-track prompt, subtitle
                // warning), not a slimmed-down copy.
                if let client, let userID, let downloadManager {
                    DownloadButton(item: episode, client: client, userID: userID, downloadManager: downloadManager, style: .overlay)
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
