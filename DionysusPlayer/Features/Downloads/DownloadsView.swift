import SwiftUI

/// The Downloads tab's landing screen: one alphabetically-sorted list
/// mixing standalone items (movies, or lone episodes) and per-show group
/// rows — see `DownloadsRow`/`DownloadsViewModel`. Reachable as a
/// `MainTabView` tab regardless of connectivity or sign-in state —
/// everything here reads straight from local storage.
///
/// Bulk delete: the trash toolbar button enters selection mode (Photos/
/// Files-style Cancel-top-left/Select-All-top-right/destructive-action
/// shape) — each row (including a whole show group, selected as one unit)
/// gets a checkbox in place of its usual navigation. The confirmation
/// dialog's asset count reflects the real total, not the row count — a
/// selected show's own episodes all count individually (see
/// `DownloadsViewModel.selectedAssetCount`).
struct DownloadsView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel: DownloadsViewModel?
    @State private var showDeleteConfirmation = false

    /// Same `.regular` gate `SearchView.usesGridLayout` uses, for the same
    /// reason — see `DownloadsGrid`'s doc comment for the measurements that
    /// motivated it. `.compact` (iPhone) keeps the existing `List`
    /// untouched.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var usesGridLayout: Bool { horizontalSizeClass == .regular }

    var body: some View {
        content
            .navigationTitle("Downloads")
            .onAppear {
                if viewModel == nil {
                    viewModel = DownloadsViewModel(downloadManager: appState.downloadManager)
                } else {
                    // Re-reads local storage fresh (e.g. a download
                    // finished, or a delete happened on a pushed detail
                    // page) — see `DownloadsViewModel`'s own doc comment
                    // for why there's no automatic observation instead.
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

    /// Presented exactly while `viewModel.retryErrorMessage` is non-`nil`;
    /// dismissing (either button, or a swipe/tap-away) clears it back to
    /// `nil` so the same message can't reappear stale on the next failure.
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

    /// `nil` — which hides `DownloadsRowView`'s retry button entirely,
    /// rather than showing it disabled — for anything that isn't a failed
    /// standalone item, or when there's no live session to retry with
    /// (`DownloadManager.retry(itemID:client:)` needs one; same gating
    /// `DownloadedPlayResumeButtonRow`'s own Retry button uses).
    private func retryAction(_ row: DownloadsRow) -> (() -> Void)? {
        guard case .standalone(let item) = row, item.status == .failed, let client = appState.apiClient else { return nil }
        return {
            guard let viewModel else { return }
            Task { await viewModel.retry(itemID: item.itemID, client: client) }
        }
    }

    /// e.g. "Delete 3 Downloads (1.24 GB)?" — falls back to the plain
    /// count-only wording when there's no size to show (see
    /// `DownloadsViewModel.selectedTotalSizeText`'s own doc comment). Two
    /// fully separate localized strings per branch, not one spliced
    /// together with the size inserted before a trailing "?" — that would
    /// bake in an English-specific punctuation position no other language
    /// is guaranteed to share.
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
                // Both live in the top nav bar, not a `.bottomBar` item —
                // this app's floating tab bar (iOS 26's default style) sits
                // at a higher z-order than `.bottomBar` and simply covers
                // it. The asset count shows in the confirmation dialog's
                // title instead, keeping this button icon-only so both fit
                // comfortably alongside Cancel/Select All.
                ToolbarItem(placement: .topBarTrailing) {
                    Button(viewModel.isAllSelected ? "Deselect All" : "Select All") {
                        viewModel.toggleSelectAll()
                    }
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
                // One identifier for both layouts — which renders is a
                // size-class detail a test should not have to know.
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
                            // Only the ordinary single-item delete — bulk
                            // selection has its own bottom-bar action, and
                            // swiping a row mid-selection would be a
                            // confusing second way to remove just one item
                            // out from under a multi-row selection.
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

    /// Landscape if *any* row is episode/show-like, decided once for the
    /// whole list or grid rather than per row — mirrors
    /// `SearchView.isLandscapeShape(_:)` and `MediaCollectionRail
    /// .usesLandscapeTiles`. So a library of only movies keeps poster-shaped
    /// artwork, and one mixing in any show switches every row to 16:9.
    /// Shared by both presentations, exactly as Search shares its own.
    private func isLandscapeShape(_ rows: [DownloadsRow]) -> Bool {
        rows.contains { $0.isLandscapeShaped }
    }

    /// `.regular`-size-class counterpart to the `List` above — see
    /// `DownloadsGrid`.
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
        // Same series-name-first convention as the list row's own
        // `rowContent` — see its comment.
        case .standalone(let item): return item.kind == .episode ? (item.seriesTitle ?? item.title) : item.title
        case .show(let group): return group.seriesTitle
        }
    }

    private func gridSubtitle(_ row: DownloadsRow) -> String? {
        switch row {
        case .standalone(let item):
            guard item.status == .completed else { return nil }
            if item.kind == .episode {
                return item.episodeLabel.map { "\($0) \u{00B7} \(item.title)" } ?? item.title
            }
            return item.yearAndDurationText
        case .show(let group):
            return String(localized: "\(group.episodeCount) Episodes")
        }
    }

    /// Mirrors the list row's `subtitleLine(for:)` for every non-completed
    /// status; `nil` once completed (the subtitle carries the real
    /// information by then).
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

    /// "Title, subtitle, status" — the same sentence the equivalent list row
    /// composes from its own stacked `Text`s, spelled out here because the
    /// tile collapses to a single accessibility element.
    private func gridAccessibilityLabel(_ row: DownloadsRow) -> String {
        [gridTitle(row), gridSubtitle(row), gridStatusText(row)]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}

/// One row of `DownloadsView`'s list — a standalone item (pushes
/// `.downloadedAsset`) or a show group (pushes `.downloadedShow`) normally;
/// in selection mode (`isSelecting`), a plain tappable row with a leading
/// checkbox instead, toggling `onToggleSelection` rather than navigating.
/// A plain `NavigationLink` as a `List`/`ForEach` row's content is fine
/// here — unlike the known bare-`NavigationLink`-in-`LazyHStack`/
/// `LazyVStack` freeze (see `LibraryRailView`'s history), `List` doesn't
/// hit that bug class.
private struct DownloadsRowView: View {
    let row: DownloadsRow
    let downloadManager: DownloadManager
    /// The whole *list's* one shape decision (`DownloadsView.isLandscapeShape(_:)`),
    /// not this row's own kind — a movie sitting in an otherwise show-heavy
    /// list gets the same landscape thumbnail every other row here does.
    /// Mirrors `SearchResultRow`'s identical parameter, and the `.regular`
    /// grid's `DownloadsGridCard`; see `MediaCollectionRail.usesLandscapeTiles`
    /// for why a mixed-shape list reads worse than a consistent one.
    ///
    /// Before this, each row picked its own image by kind *and* every
    /// thumbnail was framed 44x66 portrait regardless — so a show group's
    /// landscape still got squeezed into a poster-shaped box (reported on
    /// device, 2026-09-03).
    let isLandscape: Bool
    var isSelecting: Bool = false
    var isSelected: Bool = false
    /// `DownloadsViewModel.rowSizes[row.id]` — precomputed there rather
    /// than stat'd here on every render, see that property's own doc
    /// comment. `nil`/`0` (nothing completed to size yet) simply shows no
    /// size text rather than "0 B".
    var sizeBytes: Int64? = nil
    var isRetrying: Bool = false
    var onToggleSelection: () -> Void = {}
    /// `nil` hides the retry button entirely rather than showing it
    /// disabled — see `DownloadsView.retryAction(_:)`'s own doc comment for
    /// when that is.
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

    /// The row's actual content — identical whether it ends up inside a
    /// `NavigationLink` or a selection `Button`, per this type's own doc
    /// comment.
    @ViewBuilder
    private var rowContent: some View {
        switch row {
        case .standalone(let item):
            // A lone downloaded episode (its series has no other downloads
            // — otherwise it'd be a `.show` group instead) still needs the
            // show name visible here, mirroring `MediaItem.railTitle`/
            // `railSubtitle`'s series-name-then-"S1:E4 · Episode Name"
            // convention, since `DownloadedItem` has no `MediaItem` of its
            // own to read that from directly.
            HStack(spacing: 12) {
                thumbnail(
                    relativePath: row.artworkRelativePath(preferLandscape: isLandscape),
                    placeholderSystemImage: row.placeholderSystemImage
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.kind == .episode ? (item.seriesTitle ?? item.title) : item.title).lineLimit(1)
                    subtitleLine(for: item)
                }
                Spacer()
                // Selection mode's own trailing element takes priority over
                // the in-progress indicators below — see `sizeText`'s doc
                // comment for why it's `nil` for anything but a completed
                // row, which is what keeps this from ever fighting the
                // progress ring/spinner for the same spot in practice.
                if isSelecting, let sizeText {
                    Text(sizeText).font(.caption).foregroundStyle(.secondary)
                } else if let progress = progress(for: item) {
                    DownloadProgressRing(progress: progress)
                        .frame(width: 28, height: 28)
                } else if item.status == .downloading || item.status == .queued {
                    // See `DownloadButton.isPreparing`'s doc comment — no
                    // byte progress yet, but a plain spinner beats blank
                    // space.
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

    /// `sizeBytes`, formatted — `nil` when there's nothing to show yet
    /// (`sizeBytes` is `nil`/`0` for a row with no completed content, e.g.
    /// still downloading), so callers can `if let` around it rather than
    /// each independently guarding against a meaningless "0 B"/blank label.
    private var sizeText: String? {
        guard let sizeBytes, sizeBytes > 0 else { return nil }
        return FileSizeText.text(bytes: sizeBytes)
    }

    /// `.buttonStyle(.borderless)`, not `.plain` — this sits inside a row
    /// that's itself a `NavigationLink`'s label (outside selection mode),
    /// and `.borderless` is what lets it act as its own independent tap
    /// target instead of the surrounding `NavigationLink` swallowing the
    /// tap, the documented SwiftUI pattern for a secondary `List` row
    /// action. Icon-only, unlike `DownloadedPlayResumeButtonRow.failedRow`'s
    /// full-width labeled Retry button — this is a compact list row, not a
    /// detail page, but the same spinner-replaces-icon-while-retrying
    /// treatment and brand tint.
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

    /// Live byte progress for a standalone row still mid-download —
    /// `nil` once completed (or if it somehow failed, see `subtitleLine`).
    private func progress(for item: DownloadedItem) -> DownloadProgress? {
        guard item.status == .downloading || item.status == .queued else { return nil }
        return downloadManager.activeDownloads[item.itemID]
    }

    @ViewBuilder
    private func subtitleLine(for item: DownloadedItem) -> some View {
        switch item.status {
        case .downloading:
            if let progress = progress(for: item) {
                Text(progress.statusText).font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Preparing download…").font(.caption).foregroundStyle(.secondary)
            }
        case .queued:
            // Waiting for a concurrency slot — see `DownloadedAssetDetailView
            // .downloadStatusRow`'s doc comment on the same distinction.
            Text("Queued…").font(.caption).foregroundStyle(.secondary)
        case .failed:
            // The specific reason when there is one (e.g. `DownloadManager`'s
            // duration-validation message) — same `errorMessage ??` fallback
            // `DownloadedPlayResumeButtonRow.failedRow` already uses, so the
            // two don't disagree about what a failed download's row says.
            Text(item.errorMessage ?? String(localized: "Download Failed"))
                .font(.caption).foregroundStyle(.red)
                .lineLimit(2)
        case .paused:
            Text("Paused").font(.caption).foregroundStyle(.secondary)
        case .completed:
            if item.kind == .episode {
                // "S1:E4 · Episode Name" — same pattern as
                // `MediaItem.railSubtitle`'s episode case.
                Text(item.episodeLabel.map { "\($0) \u{00B7} \(item.title)" } ?? item.title)
                    .font(.caption).foregroundStyle(.secondary)
            } else if let yearAndDuration = item.yearAndDurationText {
                // "2019 · 1h 32m" — same pattern as `MediaItem.railSubtitle`'s
                // movie case, so a completed download reads the same as its
                // live counterpart instead of showing just a bare title.
                Text(yearAndDuration)
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityLabel(item.yearAndDurationAccessibilityText ?? yearAndDuration)
            }
        }
    }

    /// 88x50 landscape / 44x66 portrait — both are sizes this feature
    /// already uses (88x50 is exactly `DownloadedEpisodeRow`'s own thumbnail,
    /// so a lone-episode row here matches an episode row on the show
    /// subpage). Which one applies is `isLandscape`, the whole list's single
    /// decision, not the row's own kind.
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
