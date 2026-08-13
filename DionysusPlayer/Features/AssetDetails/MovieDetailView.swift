import SwiftUI

/// Detail page for a standalone movie: synopsis, play button, technical
/// details, and related content/collections.
struct MovieDetailView: View {
    let viewModel: AssetDetailViewModel
    @State private var playbackRequest: PlaybackRequest?
    /// Bumped from `fullScreenCover(onDismiss:)` — both immediately (to
    /// pick up `applyOptimisticPlaybackPosition(_:)`'s guess, already
    /// applied to `viewModel.item` by the time `onDismiss` fires) and again
    /// once `refreshItem()` finishes (to pick up the server's own
    /// confirmed values, in particular `played`).
    ///
    /// Necessary because `viewModel.item` mutating on its own isn't
    /// reliably enough to get this view's `body` to re-run. Confirmed live
    /// (2026-08-13) with direct instrumentation: while this view is covered
    /// by its own `.fullScreenCover`, `viewModel.item` changing underneath
    /// it (from either of the above) produced no further `body` evaluation
    /// at all once the cover dismissed — even though the exact same
    /// mutation correctly reached `HeroActionButtons` (a `.toolbar` item
    /// with its own independent Observation subscription, a materially
    /// different SwiftUI update path from this view's main content). A
    /// local `@State` mutated directly on this view, from a closure that's
    /// *this view's own* and reliably fires (`onDismiss`, confirmed via the
    /// same instrumentation), is what reliably forces a re-render regardless
    /// of that gap — plain `let`-input `.id()` tricks scoped to a child
    /// (`PlayResumeButtonRow`'s below) never even get a chance to run if
    /// this view's own `body` doesn't re-evaluate them in the first place.
    @State private var refreshTrigger = UUID()

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
                        // See `MediaItem.playbackProgressIdentity`'s doc
                        // comment: without this, the progress bar/Play-vs-
                        // Resume label can silently stop updating after
                        // returning from playback, since this view owns its
                        // own `@State` (the version-choice prompt) and takes
                        // `item` as a plain, non-tracked `let`.
                        .id(item.playbackProgressIdentity)

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
        // See `refreshTrigger`'s own doc comment.
        .id(refreshTrigger)
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
