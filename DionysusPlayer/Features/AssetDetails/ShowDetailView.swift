import SwiftUI

/// Detail page for a TV Show: synopsis, seasons/episodes, and a Play button
/// that resumes where the user left off (or starts from the first episode).
struct ShowDetailView: View {
    let viewModel: AssetDetailViewModel
    @State private var playbackRequest: PlaybackRequest?
    @State private var selectedSeasonID: String?

    var body: some View {
        ScrollView {
            if let item = viewModel.item {
                VStack(alignment: .leading, spacing: 20) {
                    HeroHeaderView(item: item)

                    VStack(alignment: .leading, spacing: 16) {
                        InfoMetadataRow(item: item)

                        PlayResumeButtonRow(
                            item: item,
                            onPlay: {
                                Task {
                                    if let episodeID = await viewModel.resolveSeriesPlaybackItemID() {
                                        playbackRequest = PlaybackRequest(itemID: episodeID)
                                    }
                                }
                            },
                            onRestart: {
                                Task {
                                    if let episodeID = await viewModel.resolveSeriesPlaybackItemID() {
                                        playbackRequest = PlaybackRequest(itemID: episodeID, startFromBeginning: true)
                                    }
                                }
                            }
                        )

                        // See `MovieDetailView`'s matching call site and
                        // `DetailTabsView.availableTabs`'s doc comment —
                        // a Show never actually has `technicalDetails`, so
                        // this `.id()` is a no-op in practice here, but
                        // kept for consistency with the Movie/Episode path.
                        DetailTabsView(item: item)
                            .id(item.technicalDetails == nil)
                    }
                    .padding(.horizontal)

                    if !viewModel.seasons.isEmpty {
                        SeasonEpisodeList(
                            seriesID: item.id,
                            seasons: viewModel.seasons,
                            selectedSeasonID: $selectedSeasonID,
                            onSelectEpisode: { episodeID in playbackRequest = PlaybackRequest(itemID: episodeID) }
                        )
                    }

                    if !viewModel.collections.isEmpty {
                        MediaRailView(rail: MediaCollectionRail(
                            title: String(localized: "Part of These Collections"), items: viewModel.collections
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
                .onChange(of: viewModel.seasons, initial: true) { _, seasons in
                    if selectedSeasonID == nil { selectedSeasonID = seasons.first?.id }
                }
            }
        }
        .ignoresSafeArea(edges: .top)
        .fullScreenCover(
            item: $playbackRequest,
            onDismiss: { Task { await viewModel.refreshItem() } }
        ) { request in
            PlayerView(itemID: request.itemID, startFromBeginning: request.startFromBeginning)
        }
    }
}
