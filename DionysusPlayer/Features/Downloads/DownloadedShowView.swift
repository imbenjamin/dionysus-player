import SwiftUI

/// A show's downloaded episodes — grouped into season folders only if more
/// than one season is actually downloaded; a show with episodes from just
/// one season skips straight to a flat, episode-number-sorted list instead.
/// Self-cleans back to the previous screen once its last episode is
/// deleted.
///
/// Bulk delete: same Cancel-top-left/Select-All-top-right/trash-icon shape
/// as `DownloadsView`'s own bulk delete. What one selected row actually
/// deletes depends on which layout is showing — a season row (grouped
/// case) represents every episode within that season, an episode row
/// (flat case) represents just itself. `selectedRowIDs` is safely reused
/// as either a set of season IDs or episode IDs, since the two never mix
/// mid-selection: `deleteSelected()`/`cancelSelecting()` both clear it,
/// and grouped-vs-flat only changes as a `refresh()` follows one of those.
struct DownloadedShowView: View {
    let seriesID: String
    let downloadManager: DownloadManager

    @Environment(\.dismiss) private var dismiss
    @State private var episodes: [DownloadedItem] = []
    @State private var isSelecting = false
    @State private var selectedRowIDs: Set<String> = []
    @State private var showDeleteConfirmation = false

    private var seasonIDs: Set<String> {
        Set(episodes.compactMap(\.seasonID))
    }
    private var isGroupedBySeason: Bool { seasonIDs.count > 1 }

    private var sortedEpisodes: [DownloadedItem] {
        episodes.sorted { ($0.episodeNumber ?? 0) < ($1.episodeNumber ?? 0) }
    }

    var body: some View {
        List {
            if isGroupedBySeason {
                ForEach(seasonRows, id: \.seasonID) { row in
                    if isSelecting {
                        Button(action: { toggleSelection(row.seasonID) }) {
                            HStack(spacing: 12) {
                                selectionIndicator(isSelected: selectedRowIDs.contains(row.seasonID))
                                seasonRowContent(row)
                            }
                        }
                        .buttonStyle(.plain)
                    } else {
                        NavigationLink(value: AppRoute.downloadedSeason(seriesID: seriesID, seasonID: row.seasonID)) {
                            seasonRowContent(row)
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) { deleteSeason(row) }
                        }
                    }
                }
            } else {
                ForEach(sortedEpisodes) { episode in
                    DownloadedEpisodeRow(
                        episode: episode, downloadManager: downloadManager,
                        isSelecting: isSelecting, isSelected: selectedRowIDs.contains(episode.itemID),
                        onToggleSelection: { toggleSelection(episode.itemID) }
                    )
                    .swipeActions {
                        if !isSelecting {
                            Button("Delete", role: .destructive) { delete(episode) }
                        }
                    }
                }
            }
        }
        .navigationTitle(episodes.first?.seriesTitle ?? String(localized: "Show"))
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
                    .disabled(selectedRowIDs.isEmpty)
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

    private func selectionIndicator(isSelected: Bool) -> some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(isSelected ? Color.dionysusPrimary : Color.secondary)
    }

    private struct SeasonRow { let seasonID: String; let seasonNumber: Int?; let title: String; let count: Int }
    private var seasonRows: [SeasonRow] {
        Dictionary(grouping: episodes) { $0.seasonID ?? "" }
            .map { seasonID, items in
                SeasonRow(
                    seasonID: seasonID,
                    seasonNumber: items.first?.seasonNumber,
                    title: items.first?.seasonNumber.map { String(localized: "Season \($0)") } ?? String(localized: "Season"),
                    count: items.count
                )
            }
            // By season number, not `title` — a plain string sort put
            // "Season 10" before "Season 2" for any show with 10+
            // downloaded seasons.
            .sorted { ($0.seasonNumber ?? Int.max) < ($1.seasonNumber ?? Int.max) }
    }

    private func seasonRowContent(_ row: SeasonRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.title)
            Text("\(row.count) Episodes").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func refresh() {
        episodes = downloadManager.store.visibleItems().filter { $0.seriesID == seriesID }
        if episodes.isEmpty { dismiss() }
    }

    private func delete(_ episode: DownloadedItem) {
        downloadManager.delete(itemID: episode.itemID)
        refresh()
    }

    private func deleteSeason(_ row: SeasonRow) {
        for episode in episodes where episode.seasonID == row.seasonID {
            downloadManager.delete(itemID: episode.itemID)
        }
        refresh()
    }

    // MARK: Bulk selection

    /// Whichever ids the current layout makes selectable — season ids when
    /// grouped, episode ids when flat (see this type's own doc comment).
    private var selectableRowIDs: [String] {
        isGroupedBySeason ? seasonRows.map(\.seasonID) : sortedEpisodes.map(\.itemID)
    }

    private func beginSelecting() {
        isSelecting = true
        selectedRowIDs = []
    }

    private func cancelSelecting() {
        isSelecting = false
        selectedRowIDs = []
    }

    private func toggleSelection(_ id: String) {
        if selectedRowIDs.contains(id) {
            selectedRowIDs.remove(id)
        } else {
            selectedRowIDs.insert(id)
        }
    }

    private var isAllSelected: Bool {
        !selectableRowIDs.isEmpty && selectedRowIDs.count == selectableRowIDs.count
    }

    private func toggleSelectAll() {
        selectedRowIDs = isAllSelected ? [] : Set(selectableRowIDs)
    }

    /// Total individual episodes the current selection covers — a selected
    /// season row counts its own episode count, a selected episode row
    /// (flat, single-season case) counts 1 — mirrors `DownloadsViewModel
    /// .selectedAssetCount`'s same reasoning for a selected show row there.
    private var selectedAssetCount: Int {
        if isGroupedBySeason {
            return seasonRows.filter { selectedRowIDs.contains($0.seasonID) }.reduce(0) { $0 + $1.count }
        }
        return selectedRowIDs.count
    }

    private var deleteConfirmationTitle: String {
        selectedAssetCount == 1
            ? String(localized: "Delete 1 Download?")
            : String(localized: "Delete \(selectedAssetCount) Downloads?")
    }

    /// Deletes everything the current selection covers — every episode of a
    /// selected season, not just that one row, when grouped — then exits
    /// selection mode.
    private func deleteSelected() {
        if isGroupedBySeason {
            // One pass over the already-in-memory `episodes`, not a
            // `store.visibleItems()` re-fetch per selected season.
            for episode in episodes where selectedRowIDs.contains(episode.seasonID ?? "") {
                downloadManager.delete(itemID: episode.itemID)
            }
        } else {
            for itemID in selectedRowIDs {
                downloadManager.delete(itemID: itemID)
            }
        }
        selectedRowIDs = []
        isSelecting = false
        refresh()
    }
}

/// A single downloaded episode row — shared by `DownloadedShowView`'s
/// single-season flat list and `DownloadedSeasonView`. In selection mode
/// (`isSelecting`), a plain tappable row with a leading checkbox instead of
/// its usual `NavigationLink`, toggling `onToggleSelection` rather than
/// navigating — same branch shape as `DownloadsView`'s own row.
struct DownloadedEpisodeRow: View {
    let episode: DownloadedItem
    let downloadManager: DownloadManager
    var isSelecting: Bool = false
    var isSelected: Bool = false
    var onToggleSelection: () -> Void = {}

    private var progress: DownloadProgress? {
        guard episode.status == .downloading || episode.status == .queued else { return nil }
        return downloadManager.activeDownloads[episode.itemID]
    }

    var body: some View {
        if isSelecting {
            Button(action: onToggleSelection) {
                HStack(spacing: 12) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.dionysusPrimary : Color.secondary)
                    rowContent
                }
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink(value: AppRoute.downloadedAsset(itemID: episode.itemID)) {
                rowContent
            }
        }
    }

    /// Air date and runtime together, e.g. "1 Aug 2026 · 42m" — same
    /// "next to the asset length" placement as the live
    /// `SeasonEpisodeList.EpisodeRow`'s own `episodeMetaText` (see its doc
    /// comment); this row didn't show a duration at all before, so this
    /// adds both together rather than an orphan date with nothing to pair
    /// it with.
    private var metaText: String? {
        let parts = [episode.episodeAirDateText, episode.durationText].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    @ViewBuilder
    private var rowContent: some View {
        HStack(spacing: 12) {
            LocalFileImage(
                url: (episode.thumbImagePath ?? episode.posterImagePath).map(DownloadFileStore.url(forRelativePath:)),
                targetSize: CGSize(width: 88, height: 50)
            )
                .frame(width: 88, height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 2) {
                if let episodeLabel = episode.episodeLabel {
                    Text(episodeLabel).font(.caption).foregroundStyle(.secondary)
                }
                Text(episode.title).lineLimit(1)
                if let metaText {
                    Text(metaText).font(.caption).foregroundStyle(.secondary)
                }
                statusLine
            }
            Spacer()
            if let progress {
                DownloadProgressRing(progress: progress)
                    .frame(width: 28, height: 28)
            } else if episode.status == .downloading || episode.status == .queued {
                // See `DownloadButton.isPreparing`'s doc comment — no
                // byte progress yet, but a plain spinner beats blank
                // space.
                ProgressView().controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch episode.status {
        case .downloading:
            if let progress {
                Text(progress.statusText).font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Preparing download…").font(.caption2).foregroundStyle(.secondary)
            }
        case .queued:
            // Waiting for a concurrency slot — see `DownloadedAssetDetailView
            // .downloadStatusRow`'s doc comment on the same distinction.
            Text("Queued…").font(.caption2).foregroundStyle(.secondary)
        case .failed:
            Text("Download Failed").font(.caption2).foregroundStyle(.red)
        case .paused:
            Text("Paused").font(.caption2).foregroundStyle(.secondary)
        case .completed:
            EmptyView()
        }
    }
}
