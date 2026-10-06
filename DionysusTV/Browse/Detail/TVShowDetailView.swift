import SwiftUI

/// A show's page (prototype screen 8): header and actions, season tabs, and
/// the chosen season's episodes as a rail.
///
/// The page is on the series, or on one of its episodes: the one it was
/// opened on (a Continue Watching tile) or the one chosen from the rail.
/// Select on an episode tile doesn't play it (Benjamin, 2026-10-02): the page
/// becomes that episode's, in place, with focus on Play. On an episode its
/// own name, overview and details show and Play is that episode, while
/// Watched and Favorite act on the show (`seriesItem`), as on iOS.
struct TVShowDetailView: View {
    let viewModel: AssetDetailViewModel
    /// What the page was opened on: the view model's item.
    let loadedItem: MediaItem
    let client: JellyfinAPIClient
    let userID: String
    @Binding var rememberedFocus: String?
    @Binding var isBelowHeader: Bool
    /// Whose backdrop the page draws behind everything: see `artItem`.
    @Binding var backdropItem: MediaItem?
    @Environment(\.tvOpenRoute) private var open
    @FocusState private var focus: String?
    @State private var selectedSeasonID: String?
    @State private var episodes: TVSeasonEpisodesModel?
    @State private var showsFullOverview = false
    /// The episode chosen from the rail.
    @State private var chosenEpisodeID: String?

    private var loadedEpisodes: [MediaItem] { episodes?.episodes.values.flatMap { $0 } ?? [] }

    /// What the page is on. A chosen episode is read from the season's list
    /// each time, so its resume point follows the list's refresh after
    /// playback.
    private var item: MediaItem {
        chosenEpisodeID.flatMap { id in loadedEpisodes.first { $0.id == id } } ?? loadedItem
    }

    private var isLoading: Bool { viewModel.loadState != .loaded }
    private var isEpisode: Bool { item.kind == .episode }

    /// Whose imagery shows (Benjamin, 2026-10-02): the episode the page is
    /// on; otherwise, on the series, the episode Play starts (Benjamin,
    /// 2026-10-05); otherwise the show. It changes only when the episode
    /// does: browsing the season tabs leaves it alone (Benjamin,
    /// 2026-10-05), since a tab with focus isn't a choice. Each episode
    /// falls back by itself to its season's, then its show's, where it has
    /// none of its own: the server names the nearest ancestor that has a
    /// backdrop or a logo on every item (`MediaItem.backdropImageURL`;
    /// checked on the LAN server, an American Horror Story episode names its
    /// season), which is what iOS relies on too. So a show with art per
    /// season shows the right season's on landing.
    static func artItem(episode: MediaItem?, playTarget: MediaItem?, loaded: MediaItem) -> MediaItem {
        episode ?? playTarget ?? loaded
    }

    private var artItem: MediaItem {
        Self.artItem(episode: isEpisode ? item : nil, playTarget: badgeSource, loaded: loadedItem)
    }

    /// The episode Play targets: the episode the page was opened on, or the
    /// one the view model resolved for the show.
    private var playTarget: MediaItem? { isEpisode ? item : viewModel.showPlaybackEpisode }
    /// A show's episode comes with the load; until then Play is drawn
    /// without one, so focus lands on it and stays.
    private var isResolving: Bool { !isEpisode && isLoading }

    /// A show has no media source of its own, so its format badges are
    /// those of the episode Play starts. The view model resolves that
    /// episode without its media source; the season's episode list has it.
    private var badgeSource: MediaItem? {
        guard let playTarget else { return nil }
        if !playTarget.metadataBadges.isEmpty { return playTarget }
        return loadedEpisodes.first { $0.id == playTarget.id } ?? playTarget
    }

    /// What Details describes: the episode the page is on, and on the series
    /// the episode Play starts (Benjamin, 2026-10-02). Never the show, which
    /// has no file to describe.
    private var detailsItem: MediaItem { isEpisode ? item : (badgeSource ?? item) }

    private var seasonID: String? { selectedSeasonID ?? viewModel.initialSeasonID }
    private var seasonEpisodes: [MediaItem] { seasonID.flatMap { episodes?.episodes[$0] } ?? [] }
    private var showsSeasonTabs: Bool { viewModel.seasons.count > 1 }

    private var focusIDs: [String] {
        TVDetailActions.focusIDs(playTarget: playTarget, isResolving: isResolving)
            + (item.hasDescription ? [TVDetailFocus.overview] : [])
            + (showsSeasonTabs ? viewModel.seasons.map { "season.\($0.id)" } : [])
            + seasonEpisodes.map { "episode.\($0.id)" }
            + cast.map { "cast.\($0.id)" }
            + viewModel.similar.map { "similar.\($0.id)" }
            + (TVDetailsPanel.hasRows(for: detailsItem) ? [TVDetailsPanel.focusID] : [])
    }

    /// The episode's own people when the page is on one and it has any,
    /// otherwise the show's.
    private var cast: [CastMember] {
        item.cast.isEmpty ? (viewModel.seriesItem?.cast ?? []) : item.cast
    }

    private static func isBelowHeader(_ id: String) -> Bool {
        id == TVDetailsPanel.focusID || ["season.", "episode.", "cast.", "similar."].contains { id.hasPrefix($0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                VStack(alignment: .leading, spacing: 22) {
                    // The badge row's space is always held: the badges come
                    // with the season's episodes, after the page has loaded.
                    TVDetailHeader(item: viewModel.seriesItem ?? item, logoSource: artItem, badgeSource: badgeSource, isLoading: true)
                    if isEpisode {
                        Text(verbatim: item.numberedEpisodeName).font(.title3.weight(.semibold))
                    }
                    // Reserved while loading, as on the movie page: a tile's
                    // copy of the item can arrive without its overview.
                    if item.hasDescription || isLoading {
                        Button { showsFullOverview = true } label: {
                            Text(verbatim: item.overview ?? " ")
                                .lineLimit(3, reservesSpace: true)
                                .multilineTextAlignment(.leading)
                                .frame(width: 900, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .disabled(!item.hasDescription)
                        .focused($focus, equals: TVDetailFocus.overview)
                        .accessibilityIdentifier(A11yID.TV.Detail.overview)
                    }
                    TVDetailActions(
                        viewModel: viewModel, playTarget: playTarget, statusTarget: viewModel.seriesItem ?? item,
                        isShow: true, isResolving: isResolving, focus: $focus, play: play
                    )
                    .padding(.top, 16)
                }
                // The first screen: the season tabs peek at its foot.
                .tvDetailHeaderFrame(art: artItem)

                if showsSeasonTabs {
                    seasonTabs
                }
                episodeRail
                if !cast.isEmpty {
                    TVCastRail(cast: cast, focus: $focus)
                }
                if !viewModel.similar.isEmpty {
                    TVRail(title: String(localized: "More Like This")) {
                        let shape = TVTileShape(items: viewModel.similar)
                        ForEach(viewModel.similar) { similar in
                            TVShapedTile(item: similar, shape: shape, identifier: A11yID.TV.Detail.similar(similar.id)) {
                                open(.assetDetail(itemID: similar.id, preloadedItem: similar))
                            }
                            .focused($focus, equals: "similar.\(similar.id)")
                        }
                    }
                }
                TVDetailsPanel(item: detailsItem, subject: detailsItem.kind == .episode ? detailsItem.numberedEpisodeName : nil, focus: $focus)
            }
            .padding(.top, 60)
            .padding(.bottom, 160)
        }
        .tvDetailLanding(focus: focus, isBelowHeader: $isBelowHeader, isBelow: Self.isBelowHeader)
        // The tabs behave as tabs (Benjamin, 2026-10-02): the season with
        // focus is the one on show, no Select needed. So coming into the
        // tabs from the actions or the episodes, focus is sent to the season
        // already on show: tvOS picks the tab nearest the control it left
        // (Season 2 from Play, which is wide), which would switch season on
        // the way past. The row's default focus (`seasonTabs`) gets there
        // first; this is the fallback.
        .onChange(of: focus) { old, new in
            guard let new, new.hasPrefix("season.") else { return }
            if old?.hasPrefix("season.") == true {
                selectedSeasonID = String(new.dropFirst("season.".count))
            } else if let seasonID, new != "season.\(seasonID)" {
                focus = "season.\(seasonID)"
            }
        }
        .scrollClipDisabled()
        .onChange(of: artItem, initial: true) { _, art in backdropItem = art }
        .tvClaimsFocus($focus, ids: focusIDs, remembered: $rememberedFocus)
        // A show with nothing to play loses its Play button once that's
        // known. tvOS then moves focus to the synopsis above; the actions are
        // where it was, so it goes to Watched, set until it holds since the
        // system's own move can come after ours.
        .onChange(of: isResolving) { _, resolving in
            guard !resolving, playTarget == nil, focus == TVDetailFocus.play || focus == nil else { return }
            Task { @MainActor in
                for _ in 0..<10 {
                    focus = TVDetailFocus.watched
                    try? await Task.sleep(for: .milliseconds(50))
                    if focus == TVDetailFocus.watched { break }
                }
            }
        }
        .fullScreenCover(isPresented: $showsFullOverview) {
            TVFullOverview(title: item.name, overview: item.overview ?? "")
        }
        .task(id: viewModel.seriesID) {
            guard let seriesID = viewModel.seriesID, episodes == nil else { return }
            episodes = TVSeasonEpisodesModel(client: client, userID: userID, seriesID: seriesID)
        }
        .task(id: "\(seasonID ?? "")-\(episodes == nil)") {
            if let seasonID { await episodes?.load(seasonID: seasonID) }
        }
        // Bumped by `refreshItem()` after playback or a watched change.
        .onChange(of: viewModel.episodeListRefreshToken) {
            guard let seasonID else { return }
            Task { await episodes?.load(seasonID: seasonID, force: true) }
        }
    }

    /// Focusing a tab shows its season; Select does the same, for VoiceOver.
    private var seasonTabs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 16) {
                ForEach(viewModel.seasons) { season in
                    Button { selectedSeasonID = season.id } label: {
                        Text(verbatim: season.name)
                            .fontWeight(season.id == seasonID ? .bold : .regular)
                            .opacity(season.id == seasonID ? 1 : 0.6)
                    }
                    .focused($focus, equals: "season.\(season.id)")
                    .accessibilityAddTraits(season.id == seasonID ? .isSelected : [])
                    .accessibilityIdentifier(A11yID.TV.Detail.season(season.id))
                }
            }
            .padding(.vertical, 20)
            .padding(.trailing, 80)
        }
        .scrollClipDisabled()
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
        // Entering the row, focus goes straight to the season on show
        // (`.userInitiated` applies the preference to a press into the row,
        // not only to focus placed by the system). Redirected afterwards
        // instead, tvOS's own pick drew focused for a frame first
        // (Benjamin, 2026-10-05).
        .defaultFocus($focus, seasonID.map { "season.\($0)" }, priority: .userInitiated)
    }

    private static let railHeight: CGFloat = TVTileMetrics.episode.height + 130

    @ViewBuilder
    private var episodeRail: some View {
        if let seasonID, episodes?.failedSeasons.contains(seasonID) == true {
            Text("Couldn't load this season's episodes.")
                .foregroundStyle(.secondary)
                .frame(height: Self.railHeight, alignment: .top)
        } else if (seasonID.flatMap { episodes?.episodes[$0] }?.isEmpty == true) || (seasonID == nil && !isLoading) {
            Text("No episodes available.")
                .foregroundStyle(.secondary)
                .frame(height: Self.railHeight, alignment: .top)
                .accessibilityIdentifier(A11yID.TV.Detail.noEpisodes)
        } else {
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 44) {
                    ForEach(seasonEpisodes) { episode in
                        TVLandscapeTile(
                            item: episode, size: TVTileMetrics.episode,
                            title: episode.numberedEpisodeName, subtitle: episode.durationText,
                            identifier: A11yID.TV.Detail.episode(episode.id)
                        ) {
                            // The page turns to this episode; the landing
                            // behaviour scrolls it back to the top as focus
                            // reaches Play.
                            chosenEpisodeID = episode.id
                            focus = TVDetailFocus.play
                        }
                        .focused($focus, equals: "episode.\(episode.id)")
                    }
                }
                .padding(.vertical, 30)
                .padding(.trailing, 80)
            }
            .scrollClipDisabled()
            .focusSection()
            // Held while a season loads, so switching tabs doesn't move the page.
            .frame(height: Self.railHeight, alignment: .top)
        }
    }

    private func play(_ request: PlaybackRequest) {
        TVPlayerPresenter.present(request, client: client, userID: userID) { outcome in
            viewModel.applyOptimisticPlaybackPosition(outcome)
            Task { await viewModel.refreshItem() }
        }
    }
}
