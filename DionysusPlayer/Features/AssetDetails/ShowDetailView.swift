import SwiftUI

/// Detail page for a TV Show — and, via `AssetDetailViewModel`'s
/// Series/Season/Episode consolidation, also what renders for a Season or
/// Episode tapped directly (a deep link, search result, or an episode from
/// Home's Continue Watching rail): synopsis, seasons/episodes, and a Play
/// button that resumes where the user left off.
///
/// `viewModel.item` is the Show's own item for a Series or Season tap, but
/// an *Episode's* own item for an Episode tap — see
/// `AssetDetailViewModel.item`'s doc comment for why. `isEpisodeContent`
/// below is what the body branches on to tell those two shapes apart: with
/// Episode content, this page still shows the Show's season picker/episode
/// list for browsing, but the hero/synopsis/metadata/Play button/tabs all
/// reflect that specific episode instead of the Show — its own overview,
/// artwork, technical details, and versions are what's actually playable,
/// the same way `MovieDetailView` treats a Movie. `item` can become an
/// Episode this way *without* a fresh push, too — see
/// `SeasonEpisodeList.onSelectEpisode`'s wiring below.
struct ShowDetailView: View {
    let viewModel: AssetDetailViewModel
    @State private var playbackRequest: PlaybackRequest?
    @State private var selectedSeasonID: String?
    /// See `MovieDetailView.refreshTrigger`'s doc comment — identical
    /// reasoning and fix, needed here too since this view has the exact
    /// same shape (`viewModel` held as a plain `let`, plus its own `@State`).
    @State private var refreshTrigger = UUID()

    /// `.id()`'d by a small marker overlaid near the bottom of the hero
    /// (roughly where its logo sits — see the `HeroHeaderView` call site
    /// below), so selecting a different episode from the list further down
    /// the page can scroll back up near it — otherwise the user would have
    /// no visual confirmation their tap actually did anything until they
    /// scrolled up themselves. Deliberately not the very top of the page
    /// (the hero's own top, behind the status bar/notch, is mostly wasted
    /// space) and not as low as the metadata block right below the hero
    /// either (tried first — read as scrolling too far, hiding the hero
    /// entirely) — anchoring near the logo splits the difference: still a
    /// smaller jump than all the way to the top, but leaves the hero
    /// (mostly) in view rather than skipping past it.
    private let heroAnchorID = "ShowDetailView.heroAnchor"

    /// See this type's doc comment.
    private var isEpisodeContent: Bool { viewModel.item?.kind == .episode }

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                if let item = viewModel.item {
                    VStack(alignment: .leading, spacing: 20) {
                        HeroHeaderView(item: item)
                            // The scroll anchor itself — see `heroAnchorID`'s
                            // doc comment. `BackdropLogoOverlay` bottom-aligns
                            // the logo with its own default `.padding()`
                            // (~16pt) inside a max-80pt-tall box, so ~100pt
                            // up from the hero's bottom edge lands roughly at
                            // the logo's own top edge regardless of the
                            // hero's total height (which varies by screen
                            // size — see `HeroHeaderView.heroHeight`), close
                            // enough for a scroll target without needing to
                            // reach into that shared component for its exact
                            // internal layout.
                            .overlay(alignment: .bottom) {
                                Color.clear
                                    .frame(height: 1)
                                    .id(heroAnchorID)
                                    .padding(.bottom, 100)
                            }

                        VStack(alignment: .leading, spacing: 16) {
                            // See `MovieDetailView`'s matching call site — a
                            // no-op for Show content (a Series/Season never has
                            // `technicalDetails`) but meaningful, and needed for
                            // the same reason, for Episode content.
                            InfoMetadataRow(item: item)
                                .id(item.technicalDetails == nil)

                            // Show content (Series/Season): the button targets
                            // `viewModel.showPlaybackEpisode` (resolved during
                            // `load()` — see that property's doc comment for
                            // exactly which episode and why), which is also what
                            // gives the button its "Play SXX:EYY"/"Resume
                            // SXX:EYY" label via `PlayResumeButtonRow`'s
                            // `targetEpisode`. It's built from a lightweight
                            // list-fetch DTO (not the detail page's own
                            // `Fields=MediaSources` fetch), so its
                            // `mediaVersions` is always empty in practice —
                            // `onPlay`/`onRestart`'s version-id argument stays
                            // `nil` there, a known, pre-existing gap (see
                            // `PlayResumeButtonRow`'s doc comment) rather than
                            // new behavior. Episode content plays directly
                            // instead, identical to `MovieDetailView`'s
                            // handlers — that episode *does* have real
                            // `mediaVersions` to prompt over and a preferred
                            // version worth remembering; `targetEpisode` stays
                            // `nil` there since `item` already *is* the episode.
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
                            // See `MediaItem.playbackProgressIdentity`'s doc
                            // comment. Covers both `item` and
                            // `showPlaybackEpisode` — either one can be
                            // what `PlayResumeButtonRow`'s `effectiveItem`
                            // actually resolves to (see that type's own doc
                            // comment), so either changing needs to force a
                            // fresh identity here.
                            .id("\(item.playbackProgressIdentity)-\(viewModel.showPlaybackEpisode?.playbackProgressIdentity ?? "")")

                            // See `MovieDetailView`'s matching call site and
                            // `DetailTabsView.availableTabs`'s doc comment — a
                            // no-op for Show content (same reasoning as
                            // `InfoMetadataRow` above), meaningful for Episode
                            // content.
                            DetailTabsView(item: item)
                                .id(item.technicalDetails == nil)
                        }
                        .padding(.horizontal)

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
                    // `initial: true`, not `.onAppear` — this view renders (and
                    // `.onAppear` would fire) as soon as `viewModel.item` is
                    // non-nil, which happens immediately on a preloaded item
                    // (see `AssetDetailViewModel.init`'s doc comment), well
                    // before `load()`'s network round trip actually populates
                    // `viewModel.seasons`. `.onAppear` only runs once, so it was
                    // racing that fetch: it read `seasons` while still `[]`,
                    // set `selectedSeasonID` to `nil`, and never got a second
                    // chance once the real seasons arrived — leaving the picker
                    // unselected and `SeasonEpisodeList`'s own `.task(id:
                    // selectedSeasonID)` permanently un-fired until the user
                    // manually chose a season. `onChange(of:initial:)` instead
                    // re-runs this check every time `seasons` actually changes
                    // (plus once up front for the case it's already populated
                    // by the time this view appears), so it can't miss the
                    // update however the timing falls.
                    //
                    // Prefers `viewModel.preselectedSeasonID` (a Season tapped
                    // directly, or an Episode's own parent season) over the
                    // first season — see that property's doc comment. It's set
                    // synchronously in `load()` alongside `seasons` itself, so
                    // it's already in place by the time this fires for the
                    // real (post-fetch) `seasons` value.
                    .onChange(of: viewModel.seasons, initial: true) { _, seasons in
                        if selectedSeasonID == nil { selectedSeasonID = viewModel.preselectedSeasonID ?? seasons.first?.id }
                    }
                }
            }
            // See `MovieDetailView.refreshTrigger`'s doc comment. Applied to
            // the `ScrollView` itself, not the enclosing `ScrollViewReader`
            // — keeps `scrollProxy`'s own identity (and thus
            // `heroAnchorID`-based scrolling) stable across the reset.
            .id(refreshTrigger)
            .ignoresSafeArea(edges: .top)
            // Trailing toolbar items float in the nav bar opposite the
            // system back button — same floating-over-the-hero behavior at
            // rest, same pinned-in-place behavior once the page scrolls —
            // rather than a hand-placed `.overlay` on the hero, which
            // scrolled away with it instead of staying put. See
            // `HeroActionButtons`' doc comment for the rest of the reasoning.
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HeroActionButtons(viewModel: viewModel, selectedSeasonID: selectedSeasonID)
                }
            }
        }
        .fullScreenCover(
            item: $playbackRequest,
            // Registered via `viewModel.track(_:)` — see its doc comment —
            // so `AssetDetailView`'s `.onDisappear` can cancel this if the
            // user backs out of the page again before it finishes.
            onDismiss: {
                refreshTrigger = UUID()
                viewModel.track(Task {
                    await viewModel.refreshItem()
                    refreshTrigger = UUID()
                })
            }
        ) { request in
            PlayerView(
                itemID: request.itemID, startFromBeginning: request.startFromBeginning, mediaSourceID: request.mediaSourceID,
                onPlaybackEnded: { viewModel.applyOptimisticPlaybackPosition($0) }
            )
        }
    }
}
