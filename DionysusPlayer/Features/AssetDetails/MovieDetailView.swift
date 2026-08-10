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
                            onPlay: { versionID in
                                if let versionID { viewModel.setPreferredMediaSourceID(versionID, forPlayableItem: item.id) }
                                playbackRequest = PlaybackRequest(itemID: item.id, mediaSourceID: versionID)
                            },
                            onResume: {
                                playbackRequest = PlaybackRequest(
                                    itemID: item.id, mediaSourceID: viewModel.preferredMediaSourceID(forPlayableItem: item.id)
                                )
                            },
                            onRestart: { versionID in
                                if let versionID { viewModel.setPreferredMediaSourceID(versionID, forPlayableItem: item.id) }
                                playbackRequest = PlaybackRequest(itemID: item.id, startFromBeginning: true, mediaSourceID: versionID)
                            }
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
            }
        }
        .ignoresSafeArea(edges: .top)
        // Trailing toolbar items float in the nav bar opposite the system
        // back button — same floating-over-the-hero behavior at rest, same
        // pinned-in-place behavior once the page scrolls — rather than a
        // hand-placed `.overlay` on the hero, which scrolled away with it
        // instead of staying put. See `HeroActionButtons`' doc comment for
        // the rest of the reasoning.
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HeroActionButtons(viewModel: viewModel)
            }
        }
        .fullScreenCover(
            item: $playbackRequest,
            onDismiss: { Task { await viewModel.refreshItem() } }
        ) { request in
            PlayerView(itemID: request.itemID, startFromBeginning: request.startFromBeginning, mediaSourceID: request.mediaSourceID)
        }
    }
}
