import SwiftUI

/// A show's downloaded episodes — grouped into season folders only if more
/// than one season is actually downloaded; a show with episodes from just
/// one season skips straight to a flat, episode-number-sorted list instead.
/// Self-cleans back to the previous screen once its last episode is
/// deleted.
///
/// Bulk delete uses the same shape as `DownloadsView`'s. What a selected row
/// deletes depends on the layout: a season row stands for every episode in that
/// season, an episode row for itself. `selectedRowIDs` holds either season or
/// episode ids, which never mix mid-selection — `deleteSelected()` and
/// `cancelSelecting()` both clear it, and grouped-versus-flat only changes on a
/// `refresh()` following one of those.
struct DownloadedShowView: View {
    let seriesID: String
    let downloadManager: DownloadManager

    @Environment(\.dismiss) private var dismiss
    @State private var episodes: [DownloadedItem] = []
    @State private var isSelecting = false
    @State private var selectedRowIDs: Set<String> = []
    @State private var showDeleteConfirmation = false

    /// Same `.regular` gate as `DownloadsView.usesGridLayout` (see
    /// `DownloadsGrid`). Only the flat, single-season layout gets a grid: the
    /// grouped rows are pure text with no artwork to build a tile around, and a
    /// grid of text tiles reads worse than the list, as Files shows folders as
    /// rows.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var usesGridLayout: Bool { horizontalSizeClass == .regular && !isGroupedBySeason }

    private var seasonIDs: Set<String> {
        Set(episodes.compactMap(\.seasonID))
    }
    private var isGroupedBySeason: Bool { seasonIDs.count > 1 }

    private var sortedEpisodes: [DownloadedItem] {
        episodes.sorted { ($0.episodeNumber ?? 0) < ($1.episodeNumber ?? 0) }
    }

    var body: some View {
        Group {
            if usesGridLayout {
                episodeGrid
            } else {
                listContent
            }
        }
        .navigationTitle(episodes.first?.seriesTitle ?? String(localized: "Show"))
        // Selection mode owns the whole bar, as Photos and Files do: leaving Back
        // in place gave two competing "get out of here" affordances, and popping
        // mid-selection abandoned the selection silently.
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

    /// `.regular` counterpart to the flat episode list (see `usesGridLayout`).
    /// Always landscape-shaped, since every tile is an episode.
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
                isSelected: selectedRowIDs.contains(episode.itemID),
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

    /// Mirrors `DownloadedEpisodeRow.statusLine`; `nil` once completed, where
    /// `metaText` carries the air date and duration.
    private func statusText(for episode: DownloadedEpisodeSummary) -> String? {
        switch episode.status {
        case .downloading: return progress(for: episode)?.statusText ?? String(localized: "Preparing download\u{2026}")
        case .queued: return String(localized: "Queued\u{2026}")
        case .failed: return String(localized: "Download Failed")
        case .paused: return String(localized: "Paused")
        case .completed: return episode.metaText
        }
    }

    private var listContent: some View {
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
                ForEach(sortedEpisodes.map(DownloadedEpisodeSummary.init)) { episode in
                    DownloadedEpisodeRow(
                        episode: episode, downloadManager: downloadManager,
                        isSelecting: isSelecting, isSelected: selectedRowIDs.contains(episode.itemID),
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
                    .disabled(selectedRowIDs.isEmpty)
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
            // By season number, not `title`: a string sort put "Season 10" before
            // "Season 2".
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

    /// Removes from `episodes` synchronously, then schedules the real
    /// `DownloadManager.delete(itemID:)` for the next run-loop turn rather than
    /// running it inline or via an immediate `refresh()`. Deleting a download
    /// crashed inside SwiftData's generated `DownloadedItem` accessors, reached
    /// from a `List` row mid-removal-transition.
    ///
    /// A one-turn defer wasn't enough on its own: `List`'s row-removal animation
    /// outlasts a single main-queue hop, so the transitioning row's `body`, still
    /// holding the model it was built with, could touch it again. The defer stays
    /// as cheap insurance, but the real fix is `DownloadedEpisodeSummary`, whose
    /// rows hold no live model at all.
    ///
    /// `dismiss()`, when this was the last episode, happens inside the same
    /// deferred block after the deletion. Dismissing immediately let
    /// `DownloadsView`'s `onAppear` `refresh()` re-read the store before the
    /// deferred delete landed, rebuilding its rows from a store that still had
    /// this episode and leaving a stale "Preparing download…" row until some
    /// unrelated navigation triggered another `refresh()`.
    private func delete(itemID: String) {
        episodes.removeAll { $0.itemID == itemID }
        let shouldDismiss = episodes.isEmpty
        DispatchQueue.main.async {
            downloadManager.delete(itemID: itemID)
            if shouldDismiss { dismiss() }
        }
    }

    /// Same ordering as `delete(itemID:)`, including why `dismiss()` waits inside
    /// the deferred block. All of this season's deletions land in one deferred
    /// closure rather than one per item, so `dismiss()` can't fire after only
    /// some have run.
    private func deleteSeason(_ row: SeasonRow) {
        let itemIDs = episodes.filter { $0.seasonID == row.seasonID }.map(\.itemID)
        episodes.removeAll { $0.seasonID == row.seasonID }
        let shouldDismiss = episodes.isEmpty
        DispatchQueue.main.async {
            for itemID in itemIDs { downloadManager.delete(itemID: itemID) }
            if shouldDismiss { dismiss() }
        }
    }

    // MARK: Bulk selection

    /// Whichever ids the current layout makes selectable: season ids when
    /// grouped, episode ids when flat.
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

    /// Episodes the selection covers: a season row counts its episode count, an
    /// episode row counts 1. Mirrors `DownloadsViewModel.selectedAssetCount`.
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

    /// Deletes everything the selection covers, including every episode of a
    /// selected season, then exits selection mode. Same ordering as
    /// `delete(itemID:)` — remove from `episodes` first, delete after,
    /// `dismiss()` only once they have — whose crash and stale-row bug a bulk
    /// delete hits even more easily.
    private func deleteSelected() {
        let itemIDs: [String]
        if isGroupedBySeason {
            // One pass over the in-memory `episodes`, not a
            // `store.visibleItems()` re-fetch per selected season.
            itemIDs = episodes.filter { selectedRowIDs.contains($0.seasonID ?? "") }.map(\.itemID)
        } else {
            itemIDs = Array(selectedRowIDs)
        }
        let idSet = Set(itemIDs)
        episodes.removeAll { idSet.contains($0.itemID) }
        let shouldDismiss = episodes.isEmpty
        selectedRowIDs = []
        isSelecting = false
        DispatchQueue.main.async {
            for itemID in itemIDs { downloadManager.delete(itemID: itemID) }
            if shouldDismiss { dismiss() }
        }
    }
}

/// A plain-value snapshot of what `DownloadedEpisodeRow` displays, captured from a
/// live `DownloadedItem` when the row is built, holding no reference to the model.
///
/// A `List` row's `body` can be re-invoked while its removal transition animates
/// out, even after the item has left the source array and with the SwiftData
/// delete deferred a run-loop turn. A row capturing the `@Model` directly would
/// touch it then and trap once the backing row was gone: SwiftData has no "is
/// this still valid" check, and any property access on a deleted instance
/// crashes. A snapshot has nothing left to touch.
struct DownloadedEpisodeSummary: Identifiable {
    var id: String { itemID }
    var itemID: String
    var episodeLabel: String?
    var title: String
    var thumbImagePath: String?
    var posterImagePath: String?
    var status: DownloadStatus
    /// Precomputed rather than left as a computed property read from the row's
    /// `body` — the point of this type.
    var metaText: String?
    var metaAccessibilityText: String?

    /// "S1:E1, Choosing the Right Project, 1 Jul 2005, 23 minutes" — the sentence
    /// `DownloadedEpisodeRow`'s stacked `Text`s produce for VoiceOver, spelled out
    /// for `DownloadsGridCard`, whose tile is one accessibility element. Uses
    /// `metaAccessibilityText`, not `metaText`.
    var gridAccessibilityLabel: String {
        [episodeLabel, title, metaAccessibilityText].compactMap { $0 }.joined(separator: ", ")
    }

    init(_ item: DownloadedItem) {
        itemID = item.itemID
        episodeLabel = item.episodeLabel
        title = item.title
        thumbImagePath = item.thumbImagePath
        posterImagePath = item.posterImagePath
        status = item.status
        let parts = [item.episodeAirDateText, item.durationText].compactMap { $0 }
        metaText = parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
        let accessibilityParts = [item.episodeAirDateText, item.durationAccessibilityText].compactMap { $0 }
        metaAccessibilityText = accessibilityParts.isEmpty ? nil : accessibilityParts.joined(separator: ", ")
    }
}

/// A single downloaded episode row, shared by `DownloadedShowView`'s flat list and
/// `DownloadedSeasonView`. In selection mode, a tappable row with a leading
/// checkbox instead of its `NavigationLink`, toggling `onToggleSelection` — the
/// same branch shape as `DownloadsView`'s row. Takes a `DownloadedEpisodeSummary`
/// rather than a `DownloadedItem`; see that type for why holding the live model
/// is unsafe.
struct DownloadedEpisodeRow: View {
    let episode: DownloadedEpisodeSummary
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

    @ViewBuilder
    private var rowContent: some View {
        HStack(spacing: 12) {
            LocalFileImage(
                url: (episode.thumbImagePath ?? episode.posterImagePath).map(DownloadFileStore.url(forRelativePath:)),
                targetSize: CGSize(width: 88, height: 50),
                placeholderSystemImage: "play.tv"
            )
                .frame(width: 88, height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 2) {
                if let episodeLabel = episode.episodeLabel {
                    Text(episodeLabel).font(.caption).foregroundStyle(.secondary)
                }
                Text(episode.title).lineLimit(1)
                if let metaText = episode.metaText {
                    Text(metaText).font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel(episode.metaAccessibilityText ?? metaText)
                }
                statusLine
            }
            Spacer()
            if let progress {
                DownloadProgressRing(progress: progress)
                    .frame(width: 28, height: 28)
            } else if episode.status == .downloading || episode.status == .queued {
                // See `DownloadButton.isPreparing`: no byte progress yet, but a
                // spinner beats blank space.
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
            // Waiting for a concurrency slot; see
            // `DownloadedAssetDetailView.downloadStatusRow`.
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
