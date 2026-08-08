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
                        // Keyed for the same reason as `DetailTabsView`
                        // below: `item.metadataBadges` is empty on
                        // `AssetDetailViewModel`'s preloaded, MediaSources-
                        // less item and only populates once `load()`
                        // resolves the full item, but this view holds
                        // `item` as a plain, non-`Equatable` `let` — without
                        // forcing a fresh identity here, the badge line
                        // never appears until something else remounts this
                        // view. See `DetailTabsView.availableTabs`'s doc
                        // comment for the full story.
                        InfoMetadataRow(item: item)
                            .id(item.technicalDetails == nil)

                        PlayResumeButtonRow(
                            item: item,
                            onPlay: { playbackRequest = PlaybackRequest(itemID: item.id) },
                            onRestart: { playbackRequest = PlaybackRequest(itemID: item.id, startFromBeginning: true) }
                        )

                        // Keyed on whether a "Details" tab exists at all —
                        // see `DetailTabsView.availableTabs`'s doc comment
                        // for why this `.id()` (not just passing the
                        // updated `item`) is what's actually required for
                        // the tab to appear once `technicalDetails` arrives
                        // after `AssetDetailViewModel.load()` resolves.
                        DetailTabsView(item: item)
                            .id(item.technicalDetails == nil)
                    }
                    .padding(.horizontal)

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
