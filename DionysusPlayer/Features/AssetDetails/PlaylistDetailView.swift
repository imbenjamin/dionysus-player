import SwiftUI

/// Detail page for a Playlist: no synopsis (a Playlist DTO carries no
/// overview/genres/studios/tagline/cast/technicalDetails of its own, so
/// `DetailTabsView` would only ever show a useless "No synopsis available"
/// About tab — omitted entirely rather than rendered empty), a Play/Resume
/// button that plays through the whole playlist in server-given order, and
/// `PlaylistItemList` browsing straight into any one member's own detail
/// page.
///
/// Unlike `CollectionDetailView` (a BoxSet isn't itself playable), a
/// Playlist *is* — this is structurally closer to `MovieDetailView`, just
/// with `PlayResumeButtonRow` retargeted at `viewModel.playlistResumeTarget`
/// (the specific member to play/resume, not the Playlist item itself, which
/// has no `MediaSources` of its own) and no page-level `DownloadButton`
/// next to it — a Playlist itself has nothing downloadable; each member
/// gets its own per-row overlay button instead, same as `ShowDetailView`'s
/// `SeasonEpisodeList`.
///
/// The single `.fullScreenCover`/`PlayerView` call site below is shared by
/// the main button, every row's own thumbnail tap (`PlaylistItemList`'s
/// `onPlayItem`), and every Up-Next-driven chain continuation alike — all
/// three pass `playbackQueue: viewModel.orderedPlaylistItems`, the same
/// already-fetched, already-ordered, already-audio-filtered array, so
/// starting from any point in the playlist continues sequentially through
/// the rest of it. Jellyfin has no server-side "continue this playlist"
/// mechanism (`/Shows/NextUp` is strictly Series/Season/Episode-scoped, and
/// `/Playlists/{id}/InstantMix` is an unrelated "similar tracks" radio
/// feature) — `PlayerViewModel` resolves "what's next" for this mode
/// entirely from the queue array already sitting in memory, no further
/// network calls needed.
struct PlaylistDetailView: View {
    let viewModel: AssetDetailViewModel
    @Environment(AppState.self) private var appState
    @State private var playbackRequest: PlaybackRequest?
    /// Mirrors `ShowDetailView`'s `pendingNextEpisodeID` exactly: `PlayerView`'s
    /// `onRequestNextItem` fires while this page's own `.fullScreenCover` is
    /// still presented, and reassigning `playbackRequest` directly at that
    /// point was confirmed unreliable live — so the id is stashed here and
    /// only applied from `onDismiss`, once the cover has genuinely gone
    /// through `nil` first.
    @State private var pendingNextItemID: String?
    /// See `MovieDetailView.refreshTrigger`'s doc comment — identical
    /// reasoning/fix: `viewModel` is held as a plain `let` here too, so a
    /// post-playback `viewModel.item`/`orderedPlaylistItems` change needs
    /// this local `@State` mutation to reliably force this view's metadata
    /// block to re-render while it's behind its own `.fullScreenCover`.
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
                            // See `MovieDetailView`'s identical `.id(...)` call
                            // site — without it, the progress bar/Play-vs-
                            // Resume label can silently stop updating after
                            // returning from playback.
                            .id(resumeTarget.playbackProgressIdentity)
                        }
                    }
                    .padding(.horizontal)
                    .id(refreshTrigger)

                    if !viewModel.orderedPlaylistItems.isEmpty {
                        PlaylistItemList(
                            items: viewModel.orderedPlaylistItems,
                            onPlayItem: { itemID in playbackRequest = PlaybackRequest(itemID: itemID) },
                            client: viewModel.apiClient, userID: viewModel.currentUserID, downloadManager: appState.downloadManager
                        )
                        .padding(.horizontal)
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
                // Only reached once `playbackRequest` has genuinely gone
                // through `nil` (this dismiss) — see `pendingNextItemID`'s
                // own doc comment for why the next item isn't applied
                // directly from `onRequestNextItem` instead.
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
