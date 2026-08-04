import SwiftUI

/// Detail page for a standalone movie: synopsis, play button, technical
/// details, and related content/collections.
struct MovieDetailView: View {
    let viewModel: AssetDetailViewModel
    @State private var playbackRequest: PlaybackRequest?

    var body: some View {
        ScrollView {
            if let item = viewModel.item {
                VStack(alignment: .leading, spacing: 20) {
                    HeroHeaderView(item: item)

                    VStack(alignment: .leading, spacing: 16) {
                        InfoMetadataRow(item: item)

                        PlayResumeButtonRow(
                            item: item,
                            onPlay: { playbackRequest = PlaybackRequest(itemID: item.id) },
                            onRestart: { playbackRequest = PlaybackRequest(itemID: item.id, startFromBeginning: true) }
                        )

                        if let overview = item.overview, !overview.isEmpty {
                            Text(overview)
                                .font(.body)
                        }

                        if !item.technicalSummary.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Details")
                                    .font(.headline)
                                Text(item.technicalSummary.joined(separator: " \u{00B7} "))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal)

                    if !viewModel.collections.isEmpty {
                        MediaRailView(rail: MediaCollectionRail(title: "Part of These Collections", items: viewModel.collections))
                    }

                    if !viewModel.similar.isEmpty {
                        MediaRailView(rail: MediaCollectionRail(title: "More Like This", items: viewModel.similar))
                    }
                }
                .padding(.bottom, 32)
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
