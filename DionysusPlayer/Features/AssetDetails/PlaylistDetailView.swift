import SwiftUI

/// Detail page for a Playlist: no synopsis (a Playlist DTO carries no
/// overview/genres/studios/tagline/cast/technicalDetails, so
/// `DetailTabsView` would only show an empty About tab — omitted
/// entirely), a Play/Resume button that plays through the whole playlist
/// in server-given order, and `PlaylistItemList` browsing straight into
/// any member's own detail page.
///
/// Unlike `CollectionDetailView` (a BoxSet isn't itself playable), a
/// Playlist *is* — structurally closer to `MovieDetailView`, with
/// `PlayResumeButtonRow` retargeted at `viewModel.playlistResumeTarget`
/// (the member to play/resume; the Playlist item itself has no
/// `MediaSources`) and no page-level `DownloadButton` — a Playlist has
/// nothing downloadable itself; each member gets its own per-row overlay
/// button, same as `ShowDetailView`'s `SeasonEpisodeList`.
///
/// The single `.fullScreenCover`/`PlayerView` call site below is shared by
/// the main button, every row's thumbnail tap (`PlaylistItemList`'s
/// `onPlayItem`), and every Up-Next chain continuation — all three pass
/// `playbackQueue: viewModel.orderedPlaylistItems`, so starting from any
/// point continues sequentially through the rest. Jellyfin has no
/// server-side "continue this playlist" mechanism (`/Shows/NextUp` is
/// Series/Season/Episode-scoped; `/Playlists/{id}/InstantMix` is an
/// unrelated "similar tracks" radio feature) — `PlayerViewModel` resolves
/// "what's next" here entirely from the queue array already in memory.
struct PlaylistDetailView: View {
    let viewModel: AssetDetailViewModel
    @Environment(AppState.self) private var appState
    @State private var playbackRequest: PlaybackRequest?
    /// Mirrors `ShowDetailView`'s `pendingNextEpisodeID`: `PlayerView`'s
    /// `onRequestNextItem` fires while this page's `.fullScreenCover` is
    /// still presented, and reassigning `playbackRequest` directly there
    /// was unreliable live — so the id is stashed here and applied only
    /// from `onDismiss`, once the cover has gone through `nil`.
    @State private var pendingNextItemID: String?
    /// See `MovieDetailView.refreshTrigger` — same fix: `viewModel` is a
    /// plain `let` here too, so a post-playback `viewModel.item`/
    /// `orderedPlaylistItems` change needs this `@State` mutation to force
    /// the metadata block to re-render behind its `.fullScreenCover`.
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

                        if let resumeTarget = viewModel.playlistResumeTarget {
                            PlayResumeButtonRow(
                                item: item,
                                targetEpisode: resumeTarget,
                                titleOverride: resumeTarget.episodeLabel.map { "\(resumeTarget.railTitle) \($0)" } ?? resumeTarget.railTitle,
                                onPlay: { _ in playbackRequest = PlaybackRequest(itemID: resumeTarget.id) },
                                onResume: { playbackRequest = PlaybackRequest(itemID: resumeTarget.id) },
                                onRestart: { _ in playbackRequest = PlaybackRequest(itemID: resumeTarget.id, startFromBeginning: true) }
                            )
                            // See `MovieDetailView`'s identical `.id(...)`
                            // — without it, the progress bar/Play-vs-Resume
                            // label can stop updating after playback.
                            .id(resumeTarget.playbackProgressIdentity)
                        }
                    }
                    .padding(.horizontal)
                    // Caps this column — metadata and the Play/Resume row —
                    // to a readable measure on regular width, leaving the
                    // hero above and the item list/rails below full-bleed.
                    // See `ReadableDetailColumn`.
                    //
                    // This page has no tabs panel to share the column with
                    // (a Playlist gets no `DetailTabsView`, see above), so
                    // on regular width the cap is really just constraining
                    // the Play/Resume button.
                    .readableDetailColumn()
                    .id(refreshTrigger)

                    if !viewModel.orderedPlaylistItems.isEmpty {
                        PlaylistItemList(
                            items: viewModel.orderedPlaylistItems,
                            onPlayItem: { itemID in playbackRequest = PlaybackRequest(itemID: itemID) },
                            client: viewModel.apiClient, userID: viewModel.currentUserID, downloadManager: appState.downloadManager,
                            viewModel: viewModel
                        )
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HeroActionButtons(viewModel: viewModel)
            }
        }
        .fullScreenCover(
            item: $playbackRequest,
            onDismiss: {
                // Only reached once `playbackRequest` has gone through
                // `nil` — see `pendingNextItemID`'s doc comment for why.
                if let pendingNextItemID {
                    self.pendingNextItemID = nil
                    playbackRequest = PlaybackRequest(itemID: pendingNextItemID)
                    return
                }
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
                onPlaybackEnded: { viewModel.applyOptimisticPlaybackPosition($0) },
                onRequestNextItem: { pendingNextItemID = $0 },
                playbackQueue: viewModel.orderedPlaylistItems
            )
        }
    }
}
