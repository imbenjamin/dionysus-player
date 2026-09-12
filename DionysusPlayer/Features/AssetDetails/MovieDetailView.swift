import SwiftUI

/// Detail page for a standalone movie: synopsis, play button, technical
/// details, and related content/collections.
struct MovieDetailView: View {
    let viewModel: AssetDetailViewModel
    @Environment(AppState.self) private var appState
    @State private var playbackRequest: PlaybackRequest?
    /// Bumped from `fullScreenCover(onDismiss:)`: immediately, to pick up
    /// `applyOptimisticPlaybackPosition(_:)`'s guess already applied to
    /// `viewModel.item`, and again once `refreshItem()` finishes, for the server's
    /// confirmed values — `played` in particular.
    ///
    /// Necessary because `viewModel.item` mutating isn't reliably enough to re-run
    /// this view's `body`. While the view is covered by its own
    /// `.fullScreenCover`, `viewModel.item` changing underneath it produced no
    /// `body` evaluation once the cover dismissed, even though the same mutation
    /// reached `HeroActionButtons` — a `.toolbar` item with its own Observation
    /// subscription, a different update path.
    ///
    /// What forces the re-render is the `@State` write itself, which always
    /// invalidates the view whether or not `refreshTrigger` is read, unlike
    /// `@Observable` access, which only invalidates paths that read it during
    /// `body`. The `.id(refreshTrigger)` below is a separate concern: a hard
    /// identity reset of the one metadata block that needs it. Scoping that `.id`
    /// to the whole `ScrollView` also worked but reset scroll position on every
    /// return from playback.
    @State private var refreshTrigger = UUID()

    var body: some View {
        ScrollView {
            if let item = viewModel.item {
                VStack(alignment: .leading, spacing: 20) {
                    HeroHeaderView(
                        backdropURL: item.backdropImageURL ?? item.primaryImageURL,
                        logoURL: item.logoImageURL,
                        title: item.name,
                        kind: item.kind
                    )

                    VStack(alignment: .leading, spacing: 16) {
                        InfoMetadataRow(item: item)

                        HStack(spacing: 8) {
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
                            // See `MediaItem.playbackProgressIdentity`: without
                            // this, the progress bar and Play-vs-Resume label can
                            // stop updating after playback, since this view owns
                            // `@State` and takes `item` as a non-tracked `let`.
                            .id(item.playbackProgressIdentity)

                            DownloadButton(item: item, client: viewModel.apiClient, userID: viewModel.currentUserID, downloadManager: appState.downloadManager)
                        }

                        DetailTabsView(item: item)
                            .detailTabsPanel()
                    }
                    .padding(.horizontal)
                    // Caps metadata, Play/Download and tabs to a readable measure
                    // on regular width, leaving the hero above and rails below
                    // full-bleed. See `ReadableDetailColumn`.
                    .readableDetailColumn()
                    // See `refreshTrigger`. Scoped to this metadata block, not the
                    // whole `ScrollView`: an identity reset here is enough to pick
                    // up a post-playback `item` change, and anything wider only
                    // resets scroll position.
                    .id(refreshTrigger)

                    // Between the tabs and the related-content rails: a chapter
                    // belongs to this item, like everything above, rather than
                    // pointing at others like the rails below. `item.chapters` is
                    // empty for anything without real chapters, Jellyfin's
                    // single-dummy-chapter case included — see `MediaItem.chapters`.
                    if !item.chapters.isEmpty {
                        ChapterRailView(chapters: item.chapters) { chapter in
                            playbackRequest = PlaybackRequest(
                                itemID: item.id,
                                mediaSourceID: viewModel.preferredMediaSourceID(forPlayableItem: item.id),
                                startSeconds: chapter.startSeconds
                            )
                        }
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
        // Trailing toolbar items float in the nav bar opposite the system back
        // button, staying pinned once the page scrolls, unlike a hand-placed
        // `.overlay` on the hero, which scrolled away with it. See
        // `HeroActionButtons`.
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HeroActionButtons(viewModel: viewModel)
            }
            // `ToolbarSpacer(.fixed)`, not just a second `ToolbarItem`: on iOS 26
            // adjacent trailing items share one Liquid Glass capsule, so delete
            // drew as a third glyph inside the favorite/watched group. The spacer
            // is the API for forcing the break, as in `CollectionGridView`'s
            // sort/random pair — a destructive action must not read as part of the
            // metadata group.
            if #available(iOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
            }
            // Add to Playlist, plus Delete where the server permits it — one
            // `ellipsis` overflow if both apply, otherwise whichever single action
            // does; see `AssetActionsButton`.
            ToolbarItem(placement: .topBarTrailing) {
                AssetActionsButton(viewModel: viewModel, downloadManager: appState.downloadManager)
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
            }
        ) { request in
            PlayerView(
                itemID: request.itemID, startFromBeginning: request.startFromBeginning, mediaSourceID: request.mediaSourceID,
                startSeconds: request.startSeconds,
                onPlaybackEnded: { viewModel.applyOptimisticPlaybackPosition($0) }
            )
        }
    }
}
