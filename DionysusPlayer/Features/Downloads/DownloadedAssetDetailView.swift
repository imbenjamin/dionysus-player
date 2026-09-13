import SwiftUI

/// Detail page for one offline-downloaded item, rendered entirely from the
/// `DownloadedItemMetadata` and artwork snapshot captured at download time —
/// artwork from `DownloadFileStore`, everything else from
/// `DownloadedItem`/`.metadata`. Not `AssetDetailViewModel`/`MediaItem`, which
/// assume a live `BaseItemDto` and fetch similar items and collections; those
/// only make sense against a browsable library, so they aren't offered here.
///
/// Laid out to match `MovieDetailView`/`ShowDetailView` as closely as
/// offline-only data allows, reusing the live pages' presentational pieces where
/// they had no `MediaItem` coupling: the same tilt-effect `HeroHeaderView`
/// (generalized to plain artwork URLs), `DownloadedInfoMetadataRow`,
/// `DownloadedPlayResumeButtonRow` and `DownloadedDetailTabsView` mirroring their
/// live counterparts, under the same
/// `readableDetailColumn()`/`detailTabsPanel()` modifiers. As on the live pages,
/// the title appears only in the hero — which carries the series name and, for
/// episode content, the episode's own — and an episode's "SXX:EYY" only in
/// `DownloadedPlayResumeButtonRow.buttonTitle`.
///
/// Play starts the offline `PlayerViewModel` path; "Delete Download" mirrors
/// `ProfileView`'s Sign Out/Change Server `confirmationDialog`.
struct DownloadedAssetDetailView: View {
    let itemID: String
    let downloadManager: DownloadManager
    /// `nil` when there's no live session, passed through to
    /// `DownloadedPlayResumeButtonRow`'s Retry button; see its `client` property.
    var client: JellyfinAPIClient?

    @Environment(\.dismiss) private var dismiss
    @State private var isPlayerPresented = false
    @State private var startFromBeginning = false
    /// An explicit start position from a Chapters rail tap, cleared by
    /// Play/Restart so a later play doesn't inherit it. See
    /// `PlayerView.startSeconds`.
    @State private var startSeconds: TimeInterval?
    @State private var showDeleteConfirmation = false
    /// Bumped from `fullScreenCover(onDismiss:)` to force `body` to re-run once
    /// the Player closes — the same fix as `MovieDetailView.refreshTrigger`. A
    /// view presenting a `.fullScreenCover` doesn't reliably re-run `body` because
    /// an `@Observable` property it reads changed while covered.
    /// `PlayerViewModel.stop()`'s offline path writes the session's resume
    /// position and watched state and bumps `changeCount` before `dismiss()`, but
    /// without this `@State` write the Play/Resume row could still show stale
    /// progress.
    @State private var refreshTrigger = UUID()

    /// `_ = downloadManager.store.changeCount` establishes an
    /// Observation-tracked dependency (see `DownloadStore.changeCount`); without
    /// it this page wouldn't refresh after a retry re-queued its download.
    private var downloadedItem: DownloadedItem? {
        _ = downloadManager.store.changeCount
        return downloadManager.store.item(itemID: itemID)
    }

    var body: some View {
        Group {
            if let item = downloadedItem {
                // Computed once per render and shared by
                // `DownloadedInfoMetadataRow` and `DownloadedDetailTabsView`,
                // avoiding two stats of the same file.
                let fileSizeBytes = DownloadFileStore.fileSize(forRelativePath: item.videoFilePath)
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        HeroHeaderView(
                            backdropURL: heroBackdropURL(item),
                            logoURL: item.logoImagePath.map(DownloadFileStore.url(forRelativePath:)),
                            title: item.seriesTitle ?? item.title,
                            episodeTitle: item.kind == .episode ? item.title : nil,
                            episodeNumberAccessibilityText: item.kind == .episode ? item.episodeLabelAccessibilityText : nil,
                            kind: item.kind == .episode ? .episode : .movie
                        )

                        VStack(alignment: .leading, spacing: 16) {
                            DownloadedInfoMetadataRow(item: item, fileSizeBytes: fileSizeBytes)

                            DownloadedPlayResumeButtonRow(
                                item: item,
                                downloadManager: downloadManager,
                                client: client,
                                onPlay: {
                                    startFromBeginning = false
                                    startSeconds = nil
                                    isPlayerPresented = true
                                },
                                onRestart: {
                                    startFromBeginning = true
                                    startSeconds = nil
                                    isPlayerPresented = true
                                }
                            )

                            DownloadedDetailTabsView(item: item, fileSizeBytes: fileSizeBytes)
                                .detailTabsPanel()
                        }
                        .padding(.horizontal)
                        // Same cap as `MovieDetailView`'s column; see
                        // `ReadableDetailColumn`. This page's Details tab suffered
                        // most uncapped: `DownloadedTechnicalDetailsView` reuses
                        // `SummaryRow`, putting "File Size" and "1.4 GB" at
                        // opposite edges of a 1180pt page. Hero and chapter rail
                        // stay full-bleed.
                        .readableDetailColumn()

                        // The same slot and component as the live pages' Chapters
                        // rail, sourced from the download's snapshot:
                        // `Chapter.init(downloaded:)` resolves each still to its
                        // stored `file://` copy. Empty for a download taken before
                        // chapter support existed, which hides the rail.
                        if !item.chapters.isEmpty {
                            ChapterRailView(chapters: item.chapters.map(Chapter.init(downloaded:))) { chapter in
                                startFromBeginning = false
                                startSeconds = chapter.startSeconds
                                isPlayerPresented = true
                            }
                        }
                    }
                    .padding(.bottom, 32)
                }
                // Same hero-bleeds-under-the-status-bar treatment as the live
                // detail pages; see `HeroHeaderView`.
                .ignoresSafeArea(edges: .top)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .destructive) { showDeleteConfirmation = true } label: {
                            Image(systemName: "trash").downloadsToolbarTapTarget()
                        }
                        // Without this, VoiceOver reads the SF Symbol's name
                        // ("bin"), as in `PlayResumeButtonRow`'s Restart button.
                        .accessibilityLabel(String(localized: "Delete Download"))
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
                .fullScreenCover(isPresented: $isPlayerPresented, onDismiss: { refreshTrigger = UUID() }) {
                    PlayerView(
                        itemID: item.itemID, startFromBeginning: startFromBeginning,
                        startSeconds: startSeconds, downloadedItem: item
                    )
                }
            } else {
                ErrorStateView(message: String(localized: "This download is no longer available."), retry: nil)
            }
        }
    }

    /// Backdrop, else Thumb — an episode's own still, usually present even
    /// without a Backdrop or a parent to borrow one from — else Primary.
    private func heroBackdropURL(_ item: DownloadedItem) -> URL? {
        (item.backdropImagePath ?? item.thumbImagePath ?? item.posterImagePath).map(DownloadFileStore.url(forRelativePath:))
    }
}
