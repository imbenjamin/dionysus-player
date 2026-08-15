import SwiftUI

/// Detail page for a Collection (Jellyfin "BoxSet") — a curated list of
/// (usually) movies, e.g. a trilogy or franchise. Unlike `MovieDetailView`/
/// `ShowDetailView`, a BoxSet isn't itself a playable item — there's no
/// `PlayResumeButtonRow` here — its whole purpose is browsing straight into
/// one of its member items via `CollectionItemList`.
struct CollectionDetailView: View {
    let viewModel: AssetDetailViewModel
    @State private var playbackRequest: PlaybackRequest?
    /// See `MovieDetailView.refreshTrigger`'s doc comment — identical
    /// reasoning/fix: `viewModel` is held as a plain `let` here too, so a
    /// post-playback `viewModel.item`/`collectionItems` change needs this
    /// local `@State` mutation (not `@Observable` property access alone) to
    /// reliably force this view's metadata block to re-render while it's
    /// behind its own `.fullScreenCover`.
    @State private var refreshTrigger = UUID()

    var body: some View {
        ScrollView {
            if let item = viewModel.item {
                VStack(alignment: .leading, spacing: 20) {
                    HeroHeaderView(item: item)

                    VStack(alignment: .leading, spacing: 16) {
                        InfoMetadataRow(item: item)
                            .id(item.technicalDetails == nil)

                        // A BoxSet's own `technicalDetails` is always `nil`
                        // (it has no media file of its own), so this always
                        // renders without a "Details" tab — same as
                        // `ShowDetailView`'s Show-content case. Still worth
                        // keeping for the "About" tab's genres/tagline/
                        // synopsis, and "Cast & Crew" degrades to its own
                        // empty-state message when a BoxSet has none.
                        DetailTabsView(item: item)
                            .id(item.technicalDetails == nil)
                    }
                    .padding(.horizontal)
                    .id(refreshTrigger)

                    if !viewModel.collectionItems.isEmpty {
                        CollectionItemList(
                            items: viewModel.collectionItems,
                            onPlayItem: { itemID in playbackRequest = PlaybackRequest(itemID: itemID) }
                        )
                        .padding(.horizontal)
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
            }
        }
        .ignoresSafeArea(edges: .top)
        // See `MovieDetailView`'s matching call site for the reasoning —
        // trailing toolbar items float in the nav bar rather than a
        // hand-placed `.overlay` on the hero, which would scroll away
        // with it instead of staying put.
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HeroActionButtons(viewModel: viewModel)
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
