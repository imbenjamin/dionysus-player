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

                        Button {
                            Task {
                                if let episodeID = await viewModel.resolveSeriesPlaybackItemID() {
                                    playbackRequest = PlaybackRequest(itemID: episodeID)
                                }
                            }
                        } label: {
                            Label("Play", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                        if let overview = item.overview, !overview.isEmpty {
                            Text(overview)
                                .font(.body)
                        }
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
                        MediaRailView(rail: MediaCollectionRail(title: "Part of These Collections", items: viewModel.collections))
                    }

                    if !viewModel.similar.isEmpty {
                        MediaRailView(rail: MediaCollectionRail(title: "More Like This", items: viewModel.similar))
                    }
                }
                .padding(.bottom, 32)
                .onAppear {
                    if selectedSeasonID == nil { selectedSeasonID = viewModel.seasons.first?.id }
                }
            }
        }
        .ignoresSafeArea(edges: .top)
        .fullScreenCover(item: $playbackRequest) { request in
            PlayerView(itemID: request.itemID)
        }
    }
}
