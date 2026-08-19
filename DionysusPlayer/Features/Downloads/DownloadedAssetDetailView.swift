import SwiftUI

/// Detail page for one offline-downloaded item — renders entirely from the
/// `DownloadedItemMetadata`/artwork snapshot captured at download time
/// (poster/backdrop/logo from `DownloadFileStore`, everything else from
/// `DownloadedItem`/`.metadata`), not `AssetDetailViewModel`/`MediaItem`
/// (which assume a live, network-backed `BaseItemDto` and make their own
/// network calls for similar items/collections — deliberately not offered
/// here, since those only make sense against a live, browsable library).
///
/// Deliberately laid out to match `MovieDetailView`/`ShowDetailView` as
/// closely as this page's offline-only data allows (2026-08-19): the same
/// tilt-effect hero (`HeroHeaderView`, generalized to take plain artwork
/// URLs instead of a live `MediaItem` — see its own doc comment), the same
/// two-line metadata row (`DownloadedInfoMetadataRow`, mirroring
/// `InfoMetadataRow`), the same bordered-prominent Play/Resume/Restart row
/// (`DownloadedPlayResumeButtonRow`, mirroring `PlayResumeButtonRow`), and
/// the same segmented About/Cast & Crew/Details tabs (`DownloadedDetailTabsView`,
/// mirroring `DetailTabsView`) — reusing several of the live page's own
/// presentational pieces directly (`MetadataLine`, `SummaryRow`,
/// `TrackListSection`, `CastCrewGridView`) where they had no real
/// `MediaItem` coupling to begin with. The item's own title never appears
/// as a separate text line — same as the live pages, which rely entirely
/// on the hero for that, with no second copy anywhere else on the page
/// (confirmed live, 2026-08-19, against a real Show page — an earlier
/// version of this page did duplicate it). An episode's "SXX:EYY" likewise
/// lives only in the Play/Resume button's own label
/// (`DownloadedPlayResumeButtonRow.buttonTitle`), not a line of its own.
/// The hero itself carries both the series name (`title:`) and, for
/// episode content, the specific episode's own name (`episodeTitle:`) —
/// see `HeroHeaderView`/`BackdropLogoOverlay`'s own doc comments for how
/// those two combine depending on whether a logo is available. Before this
/// (2026-08-19), the hero only ever showed the series' own logo/name, so a
/// separate plain-text series-title line was kept here to at least name
/// the show; that's redundant now that the hero conveys both names itself,
/// and was removed.
///
/// Its Play button starts the offline `PlayerViewModel` path; its
/// destructive "Delete Download" toolbar button mirrors `ProfileView`'s
/// Sign Out/Change Server `confirmationDialog` pattern.
struct DownloadedAssetDetailView: View {
    let itemID: String
    let downloadManager: DownloadManager

    @Environment(\.dismiss) private var dismiss
    @State private var isPlayerPresented = false
    @State private var startFromBeginning = false
    @State private var showDeleteConfirmation = false

    private var downloadedItem: DownloadedItem? { downloadManager.store.item(itemID: itemID) }

    var body: some View {
        Group {
            if let item = downloadedItem {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        HeroHeaderView(
                            backdropURL: heroBackdropURL(item),
                            logoURL: item.logoImagePath.map(DownloadFileStore.url(forRelativePath:)),
                            title: item.seriesTitle ?? item.title,
                            episodeTitle: item.kind == .episode ? item.title : nil
                        )

                        VStack(alignment: .leading, spacing: 16) {
                            DownloadedInfoMetadataRow(item: item)

                            DownloadedPlayResumeButtonRow(
                                item: item,
                                downloadManager: downloadManager,
                                onPlay: {
                                    startFromBeginning = false
                                    isPlayerPresented = true
                                },
                                onRestart: {
                                    startFromBeginning = true
                                    isPlayerPresented = true
                                }
                            )

                            DownloadedDetailTabsView(item: item)
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
