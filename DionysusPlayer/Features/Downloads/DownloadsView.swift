import SwiftUI

/// The Downloads tab's landing screen: one alphabetically-sorted list mixing
/// standalone items (movies, or lone episodes) and per-show group rows — see
/// `DownloadsRow`/`DownloadsViewModel`. Reachable regardless of connectivity or
/// sign-in state, since everything here reads local storage.
///
/// The trash toolbar button enters selection mode, in the Photos/Files shape of
/// Cancel top-left, Select All top-right and a destructive action: each row,
/// including a show group selected as one unit, gets a checkbox in place of its
/// navigation. The confirmation dialog counts assets rather than rows, so a
/// selected show's episodes count individually (see
/// `DownloadsViewModel.selectedAssetCount`).
struct DownloadsView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel: DownloadsViewModel?
    @State private var showDeleteConfirmation = false

    /// Same `.regular` gate as `SearchView.usesGridLayout`; see `DownloadsGrid`
    /// for the measurements behind it. `.compact` keeps the `List`.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var usesGridLayout: Bool { horizontalSizeClass == .regular }

    var body: some View {
        content
            .navigationTitle("Downloads")
            .onAppear {
                if viewModel == nil {
                    viewModel = DownloadsViewModel(downloadManager: appState.downloadManager)
                } else {
                    // Re-reads local storage: a download finished, or a delete
                    // happened on a pushed detail page. See `DownloadsViewModel`
                    // for why there's no automatic observation.
                    viewModel?.refresh()
                }
            }
            .toolbar { toolbarContent }
            .confirmationDialog(
                deleteConfirmationTitle, isPresented: $showDeleteConfirmation, titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    viewModel?.deleteSelected()
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Couldn't Retry Download", isPresented: isShowingRetryError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel?.retryErrorMessage ?? "")
            }
    }

    /// Presented while `viewModel.retryErrorMessage` is non-`nil`; any dismissal
    /// clears it, so the message can't reappear stale on the next failure.
    private var isShowingRetryError: Binding<Bool> {
        Binding(
            get: { viewModel?.retryErrorMessage != nil },
            set: { isPresented in if !isPresented { viewModel?.retryErrorMessage = nil } }
        )
    }

    private func isRetrying(_ row: DownloadsRow) -> Bool {
        guard case .standalone(let item) = row else { return false }
        return viewModel?.retryingItemIDs.contains(item.itemID) ?? false
    }

    /// `nil`, which hides `DownloadsRowView`'s retry button rather than disabling
    /// it, for anything that isn't a failed standalone item or when there's no
    /// live session to retry with — `DownloadManager.retry(itemID:client:)` needs
    /// one, the same gating `DownloadedPlayResumeButtonRow` uses.
    private func retryAction(_ row: DownloadsRow) -> (() -> Void)? {
        guard case .standalone(let item) = row, item.status == .failed, let client = appState.apiClient else { return nil }
        return {
            guard let viewModel else { return }
            Task { await viewModel.retry(itemID: item.itemID, client: client) }
        }
    }

    /// "Delete 3 Downloads (1.24 GB)?", falling back to count-only wording when
    /// there's no size to show (see
    /// `DownloadsViewModel.selectedTotalSizeText`). Two separate localized
    /// strings rather than one splicing the size in before a trailing "?", which
    /// would bake in English's punctuation position.
    private var deleteConfirmationTitle: String {
        let count = viewModel?.selectedAssetCount ?? 0
        let countText = count == 1 ? String(localized: "1 Download") : String(localized: "\(count) Downloads")
        guard let sizeText = viewModel?.selectedTotalSizeText else {
            return String(localized: "Delete \(countText)?")
        }
        return String(localized: "Delete \(countText) (\(sizeText))?")
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if let viewModel, !viewModel.rows.isEmpty {
            if viewModel.isSelecting {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { viewModel.cancelSelecting() }
                }
                // Both in the top nav bar, not `.bottomBar`: iOS 26's floating
                // tab bar sits above `.bottomBar` and covers it. The asset count
                // goes in the confirmation dialog's title, keeping this button
                // icon-only so both fit alongside Cancel/Select All.
                ToolbarItem(placement: .topBarTrailing) {
                    Button(viewModel.isAllSelected ? "Deselect All" : "Select All") {
                        viewModel.toggleSelectAll()
                    }
                    .accessibilityIdentifier(A11yID.Downloads.selectAllButton)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Image(systemName: "trash").downloadsToolbarTapTarget()
                    }
                    .disabled(viewModel.selectedRowIDs.isEmpty)
                    .accessibilityLabel(String(localized: "Delete Selected Downloads"))
                    .accessibilityIdentifier(A11yID.Downloads.deleteSelectedButton)
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        viewModel.beginSelecting()
                    } label: {
                        Image(systemName: "trash").downloadsToolbarTapTarget()
                    }
                    .accessibilityLabel(String(localized: "Select Downloads to Delete"))
                    .accessibilityIdentifier(A11yID.Downloads.selectButton)
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let viewModel {
            if viewModel.rows.isEmpty {
                ErrorStateView(
                    message: String(localized: "No downloads yet. Start downloading and they'll appear here."),
                    retry: nil,
                    icon: "square.and.arrow.down.on.square"
                )
                .accessibilityIdentifier(A11yID.Downloads.emptyState)
            } else if usesGridLayout {
                // One identifier for both layouts: which renders is a size-class
                // detail a test shouldn't know.
                grid(viewModel)
                    .accessibilityIdentifier(A11yID.Downloads.list)
            } else {
                let isLandscape = isLandscapeShape(viewModel.rows)
                List {
                    ForEach(viewModel.rows) { row in
                        DownloadsRowView(
                            row: row,
                            downloadManager: appState.downloadManager,
                            isLandscape: isLandscape,
                            isSelecting: viewModel.isSelecting,
                            isSelected: viewModel.selectedRowIDs.contains(row.id),
                            sizeBytes: viewModel.rowSizes[row.id],
                            isRetrying: isRetrying(row),
                            onToggleSelection: { viewModel.toggleSelection(row.id) },
                            onRetry: retryAction(row)
                        )
                        .swipeActions {
                            // Only the single-item delete: bulk selection has its
                            // own action, and swiping mid-selection would be a
                            // second way to remove one item out from under a
                            // multi-row selection.
                            if !viewModel.isSelecting, case .standalone(let item) = row {
                                Button("Delete", role: .destructive) { viewModel.delete(itemID: item.itemID) }
                            }
                        }
                    }
                }
                .accessibilityIdentifier(A11yID.Downloads.list)
            }
        } else {
            LoadingView()
        }
    }

    /// Landscape if any row is episode- or show-like, decided once for the whole
    /// list or grid rather than per row, as in `SearchView.isLandscapeShape(_:)`
    /// and `MediaCollectionRail.usesLandscapeTiles`: a movies-only library keeps
    /// posters, and one mixing in a show switches every row to 16:9.
    private func isLandscapeShape(_ rows: [DownloadsRow]) -> Bool {
        rows.contains { $0.isLandscapeShaped }
    }

    /// `.regular` counterpart to the `List` above; see `DownloadsGrid`.
    private func grid(_ viewModel: DownloadsViewModel) -> some View {
        let isLandscape = isLandscapeShape(viewModel.rows)
        return DownloadsGrid(items: viewModel.rows, isLandscape: isLandscape) { row, width in
            DownloadsGridCard(
                title: gridTitle(row),
                subtitle: gridSubtitle(row),
                artworkRelativePath: row.artworkRelativePath(preferLandscape: isLandscape),
                placeholderSystemImage: row.placeholderSystemImage,
                width: width,
                isLandscape: isLandscape,
                accessibilityLabel: gridAccessibilityLabel(row),
                isSelecting: viewModel.isSelecting,
                isSelected: viewModel.selectedRowIDs.contains(row.id),
                progress: gridProgress(row),
                isPreparing: isPreparing(row),
                statusText: gridStatusText(row),
                isStatusError: isFailed(row),
                sizeText: gridSizeText(row, viewModel: viewModel),
                navigationValue: route(for: row),
                onToggleSelection: { viewModel.toggleSelection(row.id) },
                onRetry: retryAction(row),
                isRetrying: isRetrying(row)
            )
        }
    }

    private func route(for row: DownloadsRow) -> AppRoute {
        switch row {
        case .standalone(let item): return .downloadedAsset(itemID: item.itemID)
        case .show(let group): return .downloadedShow(seriesID: group.seriesID)
        }
    }

    private func gridTitle(_ row: DownloadsRow) -> String {
        switch row {
        // Same series-name-first convention as the list row's `rowContent`.
        case .standalone(let item): return item.isEpisode ? (item.seriesTitle ?? item.title) : item.title
        case .show(let group): return group.seriesTitle
        }
    }

    private func gridSubtitle(_ row: DownloadsRow) -> String? {
        switch row {
        case .standalone(let item):
            guard item.status == .completed else { return nil }
            if item.isEpisode {
                return item.episodeLabel.map { "\($0) \u{00B7} \(item.title)" } ?? item.title
            }
            return item.yearAndDurationText
        case .show(let group):
            return String(localized: "\(group.episodeCount) Episodes")
        }
    }

    /// Mirrors the list row's `subtitleLine(for:)` for non-completed statuses;
    /// `nil` once completed, where the subtitle carries the information.
    private func gridStatusText(_ row: DownloadsRow) -> String? {
        guard case .standalone(let item) = row else { return nil }
        switch item.status {
        case .downloading:
            return gridProgress(row)?.statusText ?? String(localized: "Preparing download\u{2026}")
        case .queued: return String(localized: "Queued\u{2026}")
        case .failed: return item.errorMessage ?? String(localized: "Download Failed")
        case .paused: return String(localized: "Paused")
        case .completed: return nil
        }
    }

    private func gridProgress(_ row: DownloadsRow) -> DownloadProgress? {
        guard case .standalone(let item) = row,
              item.status == .downloading || item.status == .queued else { return nil }
        return appState.downloadManager.activeDownloads[item.itemID]
    }

    private func isPreparing(_ row: DownloadsRow) -> Bool {
        guard case .standalone(let item) = row else { return false }
        return (item.status == .downloading || item.status == .queued) && gridProgress(row) == nil
    }

    private func isFailed(_ row: DownloadsRow) -> Bool {
        guard case .standalone(let item) = row else { return false }
        return item.status == .failed
    }

    private func gridSizeText(_ row: DownloadsRow, viewModel: DownloadsViewModel) -> String? {
        guard let bytes = viewModel.rowSizes[row.id], bytes > 0 else { return nil }
        return FileSizeText.text(bytes: bytes)
    }

    /// "Title, subtitle, status" — the sentence the list row composes from its
    /// stacked `Text`s, spelled out here because the tile collapses to one
    /// accessibility element.
    private func gridAccessibilityLabel(_ row: DownloadsRow) -> String {
        [gridTitle(row), gridSubtitle(row), gridStatusText(row)]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}

/// One row of `DownloadsView`'s list: a standalone item pushing
/// `.downloadedAsset` or a show group pushing `.downloadedShow`; in selection
/// mode, a tappable row with a leading checkbox toggling `onToggleSelection`.
/// A bare `NavigationLink` is safe as a `List` row's content — unlike inside a
/// `LazyHStack`/`LazyVStack`, where it freezes (see `LibraryRailView`).
private struct DownloadsRowView: View {
    let row: DownloadsRow
    let downloadManager: DownloadManager
    /// The whole list's shape decision
    /// (`DownloadsView.isLandscapeShape(_:)`), not this row's kind, so a movie in
    /// a show-heavy list gets the same landscape thumbnail as every other row.
    /// Mirrors `SearchResultRow` and the grid's `DownloadsGridCard`; see
    /// `MediaCollectionRail.usesLandscapeTiles` for why a mixed-shape list reads
    /// worse.
    ///
    /// Before this, each row picked its image by kind while every thumbnail was
    /// framed 44x66 portrait regardless, squeezing a show group's landscape into
    /// a poster-shaped box.
    let isLandscape: Bool
    var isSelecting: Bool = false
    var isSelected: Bool = false
    /// `DownloadsViewModel.rowSizes[row.id]`, precomputed there rather than
    /// stat'd here on every render. `nil` or `0` — nothing completed to size yet
    /// — shows no size text rather than "0 B".
    var sizeBytes: Int64? = nil
    var isRetrying: Bool = false
    var onToggleSelection: () -> Void = {}
    /// `nil` hides the retry button rather than disabling it; see
    /// `DownloadsView.retryAction(_:)` for when.
    var onRetry: (() -> Void)? = nil

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
            NavigationLink(value: route) {
                rowContent
            }
        }
    }

    private var route: AppRoute {
        switch row {
        case .standalone(let item): return .downloadedAsset(itemID: item.itemID)
        case .show(let group): return .downloadedShow(seriesID: group.seriesID)
        }
    }

    /// The row's content, identical inside a `NavigationLink` or a selection
    /// `Button`.
    @ViewBuilder
    private var rowContent: some View {
        switch row {
        case .standalone(let item):
            // A lone downloaded episode — its series has no other downloads, or
            // this would be a `.show` group — still shows the series name,
            // following `MediaItem.railTitle`/`railSubtitle`'s
            // series-name-then-"S1:E4 · Episode Name" convention, which
            // `DownloadedItem` has no `MediaItem` to read directly.
            HStack(spacing: 12) {
                thumbnail(
                    relativePath: row.artworkRelativePath(preferLandscape: isLandscape),
                    placeholderSystemImage: row.placeholderSystemImage
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.isEpisode ? (item.seriesTitle ?? item.title) : item.title).lineLimit(1)
                    subtitleLine(for: item)
                }
                Spacer()
                // Selection mode's trailing element takes priority over the
                // in-progress indicators below. `sizeText` is `nil` for anything
                // but a completed row, so it never fights the progress
                // ring/spinner for this spot.
                if isSelecting, let sizeText {
                    Text(sizeText).font(.caption).foregroundStyle(.secondary)
                } else if let progress = progress(for: item) {
                    DownloadProgressRing(progress: progress)
                        .frame(width: 28, height: 28)
                } else if item.status == .downloading || item.status == .queued {
                    // See `DownloadButton.isPreparing`: no byte progress yet, but
                    // a spinner beats blank space.
                    ProgressView().controlSize(.small)
                } else if !isSelecting, let onRetry {
                    retryButton(action: onRetry)
                }
            }
        case .show(let group):
            HStack(spacing: 12) {
                thumbnail(
                    relativePath: row.artworkRelativePath(preferLandscape: isLandscape),
                    placeholderSystemImage: row.placeholderSystemImage
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.seriesTitle).lineLimit(1)
                    Text("\(group.episodeCount) Episodes").font(.caption).foregroundStyle(.secondary)
                }
                if isSelecting, let sizeText {
                    Spacer()
                    Text(sizeText).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// `sizeBytes`, formatted. `nil` when there's nothing to show — a row with no
    /// completed content — so callers can `if let` rather than each guarding
    /// against a meaningless "0 B".
    private var sizeText: String? {
        guard let sizeBytes, sizeBytes > 0 else { return nil }
        return FileSizeText.text(bytes: sizeBytes)
    }

    /// `.buttonStyle(.borderless)`, not `.plain`: this sits inside a row that is
    /// itself a `NavigationLink`'s label, and `.borderless` is the documented
    /// SwiftUI pattern for a secondary `List` row action that needs its own tap
    /// target rather than having the tap swallowed. Icon-only, unlike
    /// `DownloadedPlayResumeButtonRow.failedRow`'s labeled Retry button, but the
    /// same spinner-while-retrying treatment and brand tint.
    private func retryButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if isRetrying {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .buttonStyle(.borderless)
        .tint(.dionysusPrimary)
        .disabled(isRetrying)
        .accessibilityLabel(String(localized: "Retry Download"))
    }

    /// Live byte progress for a standalone row mid-download; `nil` once completed
    /// or failed (see `subtitleLine`).
    private func progress(for item: DownloadsRow.StandaloneItem) -> DownloadProgress? {
        guard item.status == .downloading || item.status == .queued else { return nil }
        return downloadManager.activeDownloads[item.itemID]
    }

    @ViewBuilder
    private func subtitleLine(for item: DownloadsRow.StandaloneItem) -> some View {
        switch item.status {
        case .downloading:
            if let progress = progress(for: item) {
                Text(progress.statusText).font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Preparing download…").font(.caption).foregroundStyle(.secondary)
            }
        case .queued:
            // Waiting for a concurrency slot; see
            // `DownloadedAssetDetailView.downloadStatusRow`.
            Text("Queued…").font(.caption).foregroundStyle(.secondary)
        case .failed:
            // The specific reason when there is one, such as `DownloadManager`'s
            // duration-validation message. Same `errorMessage ??` fallback as
            // `DownloadedPlayResumeButtonRow.failedRow`, so the two agree.
            Text(item.errorMessage ?? String(localized: "Download Failed"))
                .font(.caption).foregroundStyle(.red)
                .lineLimit(2)
        case .paused:
            Text("Paused").font(.caption).foregroundStyle(.secondary)
        case .completed:
            if item.isEpisode {
                // "S1:E4 · Episode Name", as in `MediaItem.railSubtitle`.
                Text(item.episodeLabel.map { "\($0) \u{00B7} \(item.title)" } ?? item.title)
                    .font(.caption).foregroundStyle(.secondary)
            } else if let yearAndDuration = item.yearAndDurationText {
                // "2019 · 1h 32m", as in `MediaItem.railSubtitle`, so a completed
                // download reads like its live counterpart rather than a bare
                // title.
                Text(yearAndDuration)
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityLabel(item.yearAndDurationAccessibilityText ?? yearAndDuration)
            }
        }
    }

    /// 88x50 landscape / 44x66 portrait, both sizes this feature already uses:
    /// 88x50 is `DownloadedEpisodeRow`'s thumbnail, so a lone-episode row here
    /// matches an episode row on the show subpage. Which applies is
    /// `isLandscape`, the whole list's decision.
    private var thumbnailSize: CGSize {
        isLandscape ? CGSize(width: 88, height: 50) : CGSize(width: 44, height: 66)
    }

    private func thumbnail(relativePath: String?, placeholderSystemImage: String = "film") -> some View {
        LocalFileImage(
            url: relativePath.map(DownloadFileStore.url(forRelativePath:)),
            targetSize: thumbnailSize,
            placeholderSystemImage: placeholderSystemImage
        )
            .frame(width: thumbnailSize.width, height: thumbnailSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
