import SwiftUI

/// Detail page for one offline-downloaded item — renders entirely from the
/// `DownloadedItemMetadata`/artwork snapshot captured at download time
/// (poster/backdrop/logo from `DownloadFileStore`, everything else from
/// `DownloadedItem`/`.metadata`), not `AssetDetailViewModel`/`MediaItem`
/// (which assume a live, network-backed `BaseItemDto` and make their own
/// network calls for similar items/collections — deliberately not offered
/// here, since those only make sense against a live, browsable library).
///
/// Laid out to match `MovieDetailView`/`ShowDetailView` as closely as this
/// page's offline-only data allows: the same tilt-effect hero
/// (`HeroHeaderView`, generalized to take plain artwork URLs instead of a
/// live `MediaItem`), the same two-line metadata row
/// (`DownloadedInfoMetadataRow`, mirroring `InfoMetadataRow`), the same
/// Play/Resume/Restart row (`DownloadedPlayResumeButtonRow`, mirroring
/// `PlayResumeButtonRow`), and the same segmented About/Cast & Crew/Details
/// tabs (`DownloadedDetailTabsView`, mirroring `DetailTabsView`) — reusing
/// several of the live page's own presentational pieces directly where
/// they had no real `MediaItem` coupling to begin with. The item's own
/// title never appears as a separate text line, same as the live pages —
/// it relies entirely on the hero (which carries both the series name and,
/// for episode content, the episode's own name) — and an episode's
/// "SXX:EYY" lives only in the Play/Resume button's own label
/// (`DownloadedPlayResumeButtonRow.buttonTitle`), not a line of its own.
///
/// Its Play button starts the offline `PlayerViewModel` path; its
/// destructive "Delete Download" toolbar button mirrors `ProfileView`'s
/// Sign Out/Change Server `confirmationDialog` pattern.
struct DownloadedAssetDetailView: View {
    let itemID: String
    let downloadManager: DownloadManager
    /// `nil` when there's no live session — passed straight through to
    /// `DownloadedPlayResumeButtonRow`'s own Retry button, see its `client`
    /// property's own doc comment.
    var client: JellyfinAPIClient?

    @Environment(\.dismiss) private var dismiss
    @State private var isPlayerPresented = false
    @State private var startFromBeginning = false
    @State private var showDeleteConfirmation = false

    /// `_ = downloadManager.store.changeCount` establishes a real,
    /// Observation-tracked dependency — see `DownloadStore.changeCount`'s
    /// own doc comment (without it, this page wouldn't refresh after e.g.
    /// a successful retry re-queued its download).
    private var downloadedItem: DownloadedItem? {
        _ = downloadManager.store.changeCount
        return downloadManager.store.item(itemID: itemID)
    }

    var body: some View {
        Group {
            if let item = downloadedItem {
                // Computed once per render and shared by both
                // `DownloadedInfoMetadataRow` and `DownloadedDetailTabsView`
                // — avoids two duplicate filesystem stats for the same file.
                let fileSizeBytes = DownloadFileStore.fileSize(forRelativePath: item.videoFilePath)
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        HeroHeaderView(
                            backdropURL: heroBackdropURL(item),
                            logoURL: item.logoImagePath.map(DownloadFileStore.url(forRelativePath:)),
                            title: item.seriesTitle ?? item.title,
                            episodeTitle: item.kind == .episode ? item.title : nil,
                            episodeNumberAccessibilityText: item.kind == .episode ? item.episodeLabelAccessibilityText : nil
                        )

                        VStack(alignment: .leading, spacing: 16) {
                            DownloadedInfoMetadataRow(item: item, fileSizeBytes: fileSizeBytes)

                            DownloadedPlayResumeButtonRow(
                                item: item,
                                downloadManager: downloadManager,
                                client: client,
                                onPlay: {
                                    startFromBeginning = false
                                    isPlayerPresented = true
                                },
                                onRestart: {
                                    startFromBeginning = true
                                    isPlayerPresented = true
                                }
                            )

                            DownloadedDetailTabsView(item: item, fileSizeBytes: fileSizeBytes)
                        }
                        .padding(.horizontal)
                    }
                    .padding(.bottom, 32)
                }
                // Same hero-bleeds-under-the-status-bar treatment as
                // `MovieDetailView`/`ShowDetailView` — see `HeroHeaderView`'s
                // own doc comment on why it renders flush with the screen's
                // physical top edge rather than clearing it.
                .ignoresSafeArea(edges: .top)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .destructive) { showDeleteConfirmation = true } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
                .confirmationDialog(
                    "Delete this download?", isPresented: $showDeleteConfirmation, titleVisibility: .visible
                ) {
                    Button("Delete", role: .destructive) {
                        downloadManager.delete(itemID: item.itemID)
                        dismiss()
                    }
                    Button("Cancel", role: .cancel) {}
                }
                .fullScreenCover(isPresented: $isPlayerPresented) {
                    PlayerView(itemID: item.itemID, startFromBeginning: startFromBeginning, downloadedItem: item)
                }
            } else {
                ErrorStateView(message: String(localized: "This download is no longer available."), retry: nil)
            }
        }
    }

    /// Backdrop, else Thumb (an episode's own still — usually present even
    /// when it has no Backdrop of its own or a parent to borrow one from),
    /// else Primary/poster as the last resort.
    private func heroBackdropURL(_ item: DownloadedItem) -> URL? {
        (item.backdropImagePath ?? item.thumbImagePath ?? item.posterImagePath).map(DownloadFileStore.url(forRelativePath:))
    }
}
