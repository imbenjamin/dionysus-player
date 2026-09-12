import SwiftUI

/// Detail page for a TV Show, and — via `AssetDetailViewModel`'s
/// Series/Season/Episode consolidation — for a Season or Episode tapped
/// directly: synopsis, seasons/episodes, and a Play button that resumes where
/// the user left off.
///
/// `viewModel.item` is the Show's item for a Series or Season tap but the
/// Episode's own for an Episode tap (see `AssetDetailViewModel.item`), and
/// `isEpisodeContent` is what the body branches on. With Episode content the
/// season picker and episode list still show for browsing, but the
/// hero/synopsis/metadata/Play button/tabs reflect that episode, whose
/// artwork, technical details and versions are what's playable — the same way
/// `MovieDetailView` treats a Movie. `item` can become an Episode without a
/// fresh push; see `SeasonEpisodeList.onSelectEpisode` below.
struct ShowDetailView: View {
    let viewModel: AssetDetailViewModel
    @Environment(AppState.self) private var appState
    @State private var playbackRequest: PlaybackRequest?
    /// The "Up Next" prompt's chosen next episode, staged by `PlayerView`'s
    /// `onRequestNextItem` rather than opened immediately: setting
    /// `playbackRequest` while the current `.fullScreenCover` is still
    /// presented doesn't reliably work. Applied from `onDismiss` below, once
    /// the cover has gone through `nil`.
    @State private var pendingNextEpisodeID: String?
    @State private var selectedSeasonID: String?
    /// Same reasoning and fix as `MovieDetailView.refreshTrigger`, needed here
    /// for the same view shape (`viewModel` as a plain `let` plus `@State`).
    /// Scoped more narrowly than there: wrapping `SeasonEpisodeList` in
    /// `.id(refreshTrigger)` would discard its `@State` and re-trigger its
    /// list fetch with the spinner showing — the flash
    /// `episodeListRefreshToken`'s silent-refresh path exists to avoid — so this
    /// `.id()` covers only the metadata block below.
    ///
    /// The narrower scope was verified on `MovieDetailView`'s equivalent
    /// (progress bar still updates, scroll position survives the return); the
    /// `SeasonEpisodeList` half follows from the scope excluding it rather than
    /// from a separate observation on a real Show page.
    @State private var refreshTrigger = UUID()

    /// `.id()`'d by a marker near the bottom of the hero, roughly where its logo
    /// sits, so selecting an episode from the list further down can scroll back
    /// to it — otherwise the tap has no visible effect until the user scrolls up
    /// themselves. Not the page's top, which is behind the status bar/notch, and
    /// not the metadata block below the hero, which scrolled far enough to hide
    /// the hero entirely.
    private let heroAnchorID = "ShowDetailView.heroAnchor"

    /// See this type's doc comment.
    private var isEpisodeContent: Bool { viewModel.item?.kind == .episode }

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                if let item = viewModel.item {
                    VStack(alignment: .leading, spacing: 20) {
                        // `railTitle` is the show's name for episode content
                        // (`dto.seriesName ?? name`) and `item.name` otherwise.
                        // `episodeTitle` is non-nil only for episode content,
                        // and is the only thing that names the episode in the
                        // hero — neither the logo nor its no-logo fallback does.
                        HeroHeaderView(
                            backdropURL: item.backdropImageURL ?? item.primaryImageURL,
                            logoURL: item.logoImageURL,
                            title: item.railTitle,
                            episodeTitle: isEpisodeContent ? item.name : nil,
                            episodeNumberAccessibilityText: isEpisodeContent ? item.episodeLabelAccessibilityText : nil,
                            kind: item.kind
                        )
                            // The scroll anchor; see `heroAnchorID`.
                            // `BackdropLogoOverlay` bottom-aligns the logo with
                            // ~16pt padding inside a max-80pt box, so ~100pt up
                            // from the hero's bottom edge lands near the logo's
                            // top whatever the hero's height — close enough for
                            // a scroll target without reaching into that
                            // component's internal layout.
                            .overlay(alignment: .bottom) {
                                Color.clear
                                    .frame(height: 1)
                                    .id(heroAnchorID)
                                    .padding(.bottom, 100)
                            }

                        VStack(alignment: .leading, spacing: 16) {
                            InfoMetadataRow(item: item)

                            // Show content (Series/Season) targets
                            // `viewModel.showPlaybackEpisode`, resolved during
                            // `load()`, which also gives the button its
                            // "Play SXX:EYY" label via
                            // `PlayResumeButtonRow`'s `targetEpisode`. That
                            // episode comes from a lightweight list fetch, not
                            // the detail page's `Fields=MediaSources` one, so
                            // its `mediaVersions` is always empty and the
                            // version-id argument stays `nil` — a known gap,
                            // see `PlayResumeButtonRow`.
                            //
                            // Episode content plays directly, like
                            // `MovieDetailView`: it has real `mediaVersions` to
                            // prompt over, and `targetEpisode` stays `nil`
                            // because `item` already is the episode.
                            HStack(spacing: 8) {
                                PlayResumeButtonRow(
                                    item: item,
                                    targetEpisode: isEpisodeContent ? nil : viewModel.showPlaybackEpisode,
                                    onPlay: { versionID in
                                        let targetID = isEpisodeContent ? item.id : viewModel.showPlaybackEpisode?.id
                                        guard let targetID else { return }
                                        if let versionID { viewModel.setPreferredMediaSourceID(versionID, forPlayableItem: targetID) }
                                        playbackRequest = PlaybackRequest(itemID: targetID, mediaSourceID: versionID)
                                    },
                                    onResume: {
                                        let targetID = isEpisodeContent ? item.id : viewModel.showPlaybackEpisode?.id
                                        guard let targetID else { return }
                                        playbackRequest = PlaybackRequest(
                                            itemID: targetID, mediaSourceID: viewModel.preferredMediaSourceID(forPlayableItem: targetID)
                                        )
                                    },
                                    onRestart: { versionID in
                                        let targetID = isEpisodeContent ? item.id : viewModel.showPlaybackEpisode?.id
                                        guard let targetID else { return }
                                        if let versionID { viewModel.setPreferredMediaSourceID(versionID, forPlayableItem: targetID) }
                                        playbackRequest = PlaybackRequest(itemID: targetID, startFromBeginning: true, mediaSourceID: versionID)
                                    }
                                )
                                // See `MediaItem.playbackProgressIdentity`.
                                // Covers both `item` and `showPlaybackEpisode`,
                                // since `PlayResumeButtonRow`'s `effectiveItem`
                                // can resolve to either, so either changing must
                                // force a fresh identity.
                                .id("\(item.playbackProgressIdentity)-\(viewModel.showPlaybackEpisode?.playbackProgressIdentity ?? "")")

                                // Episode content only: a Series/Season page has
                                // no single file to download, since
                                // `showPlaybackEpisode` isn't a stable "the
                                // thing this page represents" the way a Movie or
                                // Episode's `item` is. Downloading a whole show
                                // isn't supported in v1.
                                if isEpisodeContent {
                                    DownloadButton(item: item, client: viewModel.apiClient, userID: viewModel.currentUserID, downloadManager: appState.downloadManager)
                                }
                            }

                            DetailTabsView(item: item)
                                .detailTabsPanel()
                        }
                        .padding(.horizontal)
                        // Caps metadata, Play/Download and tabs to a readable
                        // measure on regular width, leaving the hero above and
                        // the episode list below full-bleed. See
                        // `ReadableDetailColumn` for what goes wrong without it
                        // at 820pt/1180pt.
                        //
                        // Series content's lone Play button fills the column at
                        // 568pt rather than the 500pt the Movie and Episode
                        // variants leave for a `DownloadButton`: there's no
                        // second button here (see the `isEpisodeContent` gate
                        // above).
                        .readableDetailColumn()
                        // See `refreshTrigger`. Scoped to this metadata block,
                        // not the whole `ScrollView` and especially not
                        // `SeasonEpisodeList`: an identity reset here is enough
                        // to pick up a post-playback
                        // `item`/`showPlaybackEpisode` change, and anything
                        // wider only resets scroll position and re-flashes the
                        // episode list's spinner.
                        .id(refreshTrigger)

                        // Episode-only, in the same slot `MovieDetailView` uses
                        // (after the tabs, before anything pointing at other
                        // items): chapters describe the single item the hero and
                        // Play button represent, which Series/Season content
                        // doesn't have. A Series DTO carries no chapters anyway,
                        // so the gate is about intent, not correctness.
                        if isEpisodeContent, !item.chapters.isEmpty {
                            ChapterRailView(chapters: item.chapters) { chapter in
                                playbackRequest = PlaybackRequest(
                                    itemID: item.id,
                                    mediaSourceID: viewModel.preferredMediaSourceID(forPlayableItem: item.id),
                                    startSeconds: chapter.startSeconds
                                )
                            }
                        }

                        if let seriesID = viewModel.seriesID, !viewModel.seasons.isEmpty {
                            SeasonEpisodeList(
                                seriesID: seriesID,
                                seasons: viewModel.seasons,
                                selectedSeasonID: $selectedSeasonID,
                                refreshToken: viewModel.episodeListRefreshToken,
                                currentEpisodeID: isEpisodeContent ? item.id : nil,
                                onPlayEpisode: { episodeID in playbackRequest = PlaybackRequest(itemID: episodeID) },
                                onSelectEpisode: { episodeID in
                                    Task {
                                        await viewModel.selectEpisode(episodeID)
                                        withAnimation { scrollProxy.scrollTo(heroAnchorID, anchor: .top) }
                                    }
                                }
                            )
                        }

                        if !viewModel.collections.isEmpty {
                            MediaRailView(rail: MediaCollectionRail(
                                title: String(localized: "Included In"), items: viewModel.collections
                            ))
                        }

                        if !viewModel.similar.isEmpty {
                            MediaRailView(rail: MediaCollectionRail(
                                title: String(localized: "More Like This"), items: viewModel.similar
                            ))
                        }
                    }
                    .padding(.bottom, 32)
                    // `initial: true`, not `.onAppear`: this view renders as
                    // soon as `viewModel.item` is non-nil, immediately for a
                    // preloaded item, well before `load()` populates
                    // `viewModel.seasons`. `.onAppear` runs once, so it read
                    // `seasons` while still `[]`, left `selectedSeasonID` nil,
                    // and never fired again — the picker stayed unselected and
                    // `SeasonEpisodeList`'s `.task(id: selectedSeasonID)` never
                    // ran until the user chose a season by hand.
                    // `onChange(of:initial:)` re-runs on every `seasons` change,
                    // plus once up front if it's already populated.
                    //
                    // Prefers `viewModel.preselectedSeasonID` — a Season tapped
                    // directly, or an Episode's parent season — over the first
                    // season. It's set synchronously in `load()` alongside
                    // `seasons`, so it's in place by the time this fires.
                    .onChange(of: viewModel.seasons, initial: true) { _, seasons in
                        if selectedSeasonID == nil { selectedSeasonID = viewModel.preselectedSeasonID ?? seasons.first?.id }
                    }
                    // Keeps the season picker following the displayed episode.
                    // Only `AssetDetailViewModel.advanceToNextEpisodeIfCompleted()`
                    // needs it: `SeasonEpisodeList.onSelectEpisode`, the other
                    // caller of `selectEpisode(_:)`, can only pick from the
                    // already-selected season, while advancing past a season's
                    // last episode crosses a boundary. Guarded to Episode
                    // content and an actual mismatch, so it no-ops for every
                    // other `item` change.
                    .onChange(of: viewModel.item?.id) { _, _ in
                        if isEpisodeContent, let preselectedSeasonID = viewModel.preselectedSeasonID,
                           selectedSeasonID != preselectedSeasonID {
                            selectedSeasonID = preselectedSeasonID
                        }
                    }
                }
            }
            .ignoresSafeArea(edges: .top)
            // Trailing toolbar items float in the nav bar opposite the system
            // back button, staying pinned once the page scrolls, unlike a
            // hand-placed `.overlay` on the hero, which scrolled away with it.
            // See `HeroActionButtons`.
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HeroActionButtons(viewModel: viewModel, selectedSeasonID: selectedSeasonID)
                }
                // `ToolbarSpacer(.fixed)`, not just a second `ToolbarItem`: on
                // iOS 26 adjacent trailing items share one Liquid Glass capsule,
                // so delete drew as a third glyph inside the favorite/watched
                // group. The spacer is the API for forcing the break, as in
                // `CollectionGridView`'s sort/random pair — a destructive action
                // must not read as part of the metadata group.
                if #available(iOS 26.0, *) {
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                }
                // Offers Show/Season/Episode independently for Add to Playlist
                // and Delete, the latter only where the server permits it; see
                // `AssetActionsButton`.
                ToolbarItem(placement: .topBarTrailing) {
                    AssetActionsButton(
                        viewModel: viewModel,
                        downloadManager: appState.downloadManager,
                        selectedSeasonID: selectedSeasonID
                    )
                }
            }
        }
        .fullScreenCover(
            item: $playbackRequest,
            // Registered via `viewModel.track(_:)` so `AssetDetailView`'s
            // `.onDisappear` can cancel it if the user backs out first.
            onDismiss: {
                refreshTrigger = UUID()
                viewModel.track(Task {
                    await viewModel.refreshItem()
                    refreshTrigger = UUID()
                })
                // Only reached once `playbackRequest` has gone through `nil`;
                // see `pendingNextEpisodeID` for why `onRequestNextItem` can't
                // set it directly.
                if let pendingNextEpisodeID {
                    self.pendingNextEpisodeID = nil
                    playbackRequest = PlaybackRequest(itemID: pendingNextEpisodeID)
                }
            }
        ) { request in
            PlayerView(
                itemID: request.itemID, startFromBeginning: request.startFromBeginning, mediaSourceID: request.mediaSourceID,
                startSeconds: request.startSeconds,
                onPlaybackEnded: { viewModel.applyOptimisticPlaybackPosition($0) },
                onRequestNextItem: { pendingNextEpisodeID = $0 }
            )
        }
    }
}
