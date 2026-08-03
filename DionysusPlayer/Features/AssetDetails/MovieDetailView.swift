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

                        Button {
                            playbackRequest = PlaybackRequest(itemID: item.id)
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
        .fullScreenCover(item: $playbackRequest) { request in
            PlayerView(itemID: request.itemID)
        }
    }
}
