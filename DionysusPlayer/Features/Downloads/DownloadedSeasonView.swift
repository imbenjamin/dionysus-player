import SwiftUI

/// One season's downloaded episodes — only ever pushed from
/// `DownloadedShowView` when that show has episodes downloaded from more
/// than one season. Flat list, sorted by episode number; self-cleans back
/// once its last episode is deleted, same as `DownloadedShowView`.
///
/// Bulk delete: same Cancel-top-left/Select-All-top-right/trash-icon shape
/// as `DownloadsView`'s own bulk delete (see that view's doc comment for
/// why it's the top nav bar, not `.bottomBar`) — every row here is a single
/// episode, so there's no group-vs-leaf distinction to make the way
/// `DownloadedShowView` has to.
struct DownloadedSeasonView: View {
    let seriesID: String
    let seasonID: String
    let downloadManager: DownloadManager

    @Environment(\.dismiss) private var dismiss
    @State private var episodes: [DownloadedItem] = []
    @State private var isSelecting = false
    @State private var selectedEpisodeIDs: Set<String> = []
    @State private var showDeleteConfirmation = false

    private var sortedEpisodes: [DownloadedItem] {
        episodes.sorted { ($0.episodeNumber ?? 0) < ($1.episodeNumber ?? 0) }
    }

    /// Same `.regular` gate as `DownloadsView.usesGridLayout` — see
    /// `DownloadsGrid`'s doc comment. Unconditional here (unlike
    /// `DownloadedShowView`'s), since every row on this screen is an
    /// episode with its own artwork.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var usesGridLayout: Bool { horizontalSizeClass == .regular }

    var body: some View {
        Group {
            if usesGridLayout {
                episodeGrid
            } else {
                listContent
            }
        }
        .navigationTitle(episodes.first?.seasonNumber.map { String(localized: "Season \($0)") } ?? String(localized: "Season"))
        // See `DownloadedShowView`'s identical modifier for why.
        .navigationBarBackButtonHidden(isSelecting)
        .onAppear(perform: refresh)
        .toolbar { toolbarContent }
        .confirmationDialog(
            deleteConfirmationTitle, isPresented: $showDeleteConfirmation, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { deleteSelected() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var listContent: some View {
        List {
            ForEach(sortedEpisodes.map(DownloadedEpisodeSummary.init)) { episode in
                DownloadedEpisodeRow(
                    episode: episode, downloadManager: downloadManager,
                    isSelecting: isSelecting, isSelected: selectedEpisodeIDs.contains(episode.itemID),
                    onToggleSelection: { toggleSelection(episode.itemID) }
                )
                .swipeActions {
                    if !isSelecting {
                        Button("Delete", role: .destructive) { delete(itemID: episode.itemID) }
                    }
                }
            }
        }
    }

    /// `.regular`-size-class counterpart to `listContent` — see
    /// `usesGridLayout`. Always landscape-shaped: every tile is an episode.
    private var episodeGrid: some View {
        DownloadsGrid(items: sortedEpisodes.map(DownloadedEpisodeSummary.init), isLandscape: true) { episode, width in
            DownloadsGridCard(
                title: episode.title,
                subtitle: episode.episodeLabel,
                artworkRelativePath: episode.thumbImagePath ?? episode.posterImagePath,
                placeholderSystemImage: "play.tv",
                width: width,
                isLandscape: true,
                accessibilityLabel: episode.gridAccessibilityLabel,
                isSelecting: isSelecting,
                isSelected: selectedEpisodeIDs.contains(episode.itemID),
                progress: progress(for: episode),
                isPreparing: isPreparing(episode),
                statusText: statusText(for: episode),
                isStatusError: episode.status == .failed,
                navigationValue: .downloadedAsset(itemID: episode.itemID),
                onToggleSelection: { toggleSelection(episode.itemID) }
            )
        }
    }

    private func progress(for episode: DownloadedEpisodeSummary) -> DownloadProgress? {
        guard episode.status == .downloading || episode.status == .queued else { return nil }
        return downloadManager.activeDownloads[episode.itemID]
    }

    private func isPreparing(_ episode: DownloadedEpisodeSummary) -> Bool {
        (episode.status == .downloading || episode.status == .queued) && progress(for: episode) == nil
    }

    /// Mirrors `DownloadedShowView.statusText(for:)` — same rules, same
    /// completed-case fallback to the air date/duration line.
    private func statusText(for episode: DownloadedEpisodeSummary) -> String? {
        switch episode.status {
        case .downloading: return progress(for: episode)?.statusText ?? String(localized: "Preparing download\u{2026}")
        case .queued: return String(localized: "Queued\u{2026}")
        case .failed: return String(localized: "Download Failed")
        case .paused: return String(localized: "Paused")
        case .completed: return episode.metaText
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if !episodes.isEmpty {
            if isSelecting {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancelSelecting() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isAllSelected ? "Deselect All" : "Select All") { toggleSelectAll() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Image(systemName: "trash").downloadsToolbarTapTarget()
                    }
                    .disabled(selectedEpisodeIDs.isEmpty)
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        beginSelecting()
                    } label: {
                        Image(systemName: "trash").downloadsToolbarTapTarget()
                    }
                }
            }
        }
    }

    private func refresh() {
        episodes = downloadManager.store.visibleItems().filter { $0.seriesID == seriesID && $0.seasonID == seasonID }
        if episodes.isEmpty { dismiss() }
    }

    /// Removes from `episodes` first, synchronously, and only *then*
    /// schedules the real `DownloadManager.delete(itemID:)` (which deletes
    /// the underlying SwiftData object) for the next run-loop turn — see
    /// `DownloadedShowView.delete(itemID:)`'s doc comment for the
    /// confirmed-live crash this avoids, `DownloadedEpisodeSummary`'s doc
    /// comment for the actual fix (rows never hold a live model reference
    /// in the first place), and that same `delete(itemID:)`'s doc comment
    /// again for why `dismiss()` — when this was the last episode — has to
    /// wait inside this same deferred block rather than firing immediately
    /// (otherwise `DownloadedShowView`'s own `refresh()`, triggered by the
    /// pop, can race ahead of the real deletion and show a stale row).
    private func delete(itemID: String) {
        episodes.removeAll { $0.itemID == itemID }
        let shouldDismiss = episodes.isEmpty
        DispatchQueue.main.async {
            downloadManager.delete(itemID: itemID)
            if shouldDismiss { dismiss() }
        }
    }

    // MARK: Bulk selection

    private func beginSelecting() {
        isSelecting = true
        selectedEpisodeIDs = []
    }

    private func cancelSelecting() {
        isSelecting = false
        selectedEpisodeIDs = []
    }

    private func toggleSelection(_ itemID: String) {
        if selectedEpisodeIDs.contains(itemID) {
            selectedEpisodeIDs.remove(itemID)
        } else {
            selectedEpisodeIDs.insert(itemID)
        }
    }

    private var isAllSelected: Bool {
        !episodes.isEmpty && selectedEpisodeIDs.count == episodes.count
    }

    private func toggleSelectAll() {
        selectedEpisodeIDs = isAllSelected ? [] : Set(episodes.map(\.itemID))
    }

    private var deleteConfirmationTitle: String {
        selectedEpisodeIDs.count == 1
            ? String(localized: "Delete 1 Download?")
            : String(localized: "Delete \(selectedEpisodeIDs.count) Downloads?")
    }

    /// Same ordering as `delete(itemID:)` — see its doc comment. All of
    /// this selection's deletions land in the *same* deferred closure (not
    /// one per item), same reasoning as `DownloadedShowView.deleteSeason(_:)`:
    /// `dismiss()` can't fire after only some of them have actually run.
    private func deleteSelected() {
        let itemIDs = Array(selectedEpisodeIDs)
        episodes.removeAll { selectedEpisodeIDs.contains($0.itemID) }
        let shouldDismiss = episodes.isEmpty
        selectedEpisodeIDs = []
        isSelecting = false
        DispatchQueue.main.async {
            for itemID in itemIDs { downloadManager.delete(itemID: itemID) }
            if shouldDismiss { dismiss() }
        }
    }
}
