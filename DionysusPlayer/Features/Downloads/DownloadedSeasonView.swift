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

    var body: some View {
        List {
            ForEach(sortedEpisodes) { episode in
                DownloadedEpisodeRow(
                    episode: episode, downloadManager: downloadManager,
                    isSelecting: isSelecting, isSelected: selectedEpisodeIDs.contains(episode.itemID),
                    onToggleSelection: { toggleSelection(episode.itemID) }
                )
                .swipeActions {
                    if !isSelecting {
                        Button("Delete", role: .destructive) { delete(episode) }
                    }
                }
            }
        }
        .navigationTitle(episodes.first?.seasonNumber.map { String(localized: "Season \($0)") } ?? String(localized: "Season"))
        .onAppear(perform: refresh)
        .toolbar { toolbarContent }
        .confirmationDialog(
            deleteConfirmationTitle, isPresented: $showDeleteConfirmation, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { deleteSelected() }
            Button("Cancel", role: .cancel) {}
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
                        Image(systemName: "trash")
                    }
                    .disabled(selectedEpisodeIDs.isEmpty)
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        beginSelecting()
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
    }

    private func refresh() {
        episodes = downloadManager.store.visibleItems().filter { $0.seriesID == seriesID && $0.seasonID == seasonID }
        if episodes.isEmpty { dismiss() }
    }

    private func delete(_ episode: DownloadedItem) {
        downloadManager.delete(itemID: episode.itemID)
        refresh()
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

    private func deleteSelected() {
        for itemID in selectedEpisodeIDs {
            downloadManager.delete(itemID: itemID)
        }
        selectedEpisodeIDs = []
        isSelecting = false
        refresh()
    }
}
