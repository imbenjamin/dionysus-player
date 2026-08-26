import SwiftUI

/// The Downloads tab's landing screen: one alphabetically-sorted list
/// mixing standalone items (movies, or lone episodes) and per-show group
/// rows — see `DownloadsRow`/`DownloadsViewModel`. Reachable both as a
/// `MainTabView` tab and, with no live session required, from `RootView`'s
/// `.offline` "View Downloads" escape hatch — everything here reads
/// straight from local storage.
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
    }

    private var deleteConfirmationTitle: String {
        let count = viewModel?.selectedAssetCount ?? 0
        return count == 1
            ? String(localized: "Delete 1 Download?")
            : String(localized: "Delete \(count) Downloads?")
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
                        Image(systemName: "trash")
                    }
                    .disabled(viewModel.selectedRowIDs.isEmpty)
                    .accessibilityLabel(String(localized: "Delete Selected Downloads"))
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        viewModel.beginSelecting()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel(String(localized: "Select Downloads to Delete"))
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
            } else {
                List {
                    ForEach(viewModel.rows) { row in
                        DownloadsRowView(
                            row: row,
                            downloadManager: appState.downloadManager,
                            isSelecting: viewModel.isSelecting,
                            isSelected: viewModel.selectedRowIDs.contains(row.id),
                            onToggleSelection: { viewModel.toggleSelection(row.id) }
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
            }
        } else {
            LoadingView()
        }
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
    var isSelecting: Bool = false
    var isSelected: Bool = false
    var onToggleSelection: () -> Void = {}

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
        case .show(let seriesID, _, _, _): return .downloadedShow(seriesID: seriesID)
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
                thumbnail(relativePath: item.kind == .episode ? (item.thumbImagePath ?? item.posterImagePath) : item.posterImagePath)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.kind == .episode ? (item.seriesTitle ?? item.title) : item.title).lineLimit(1)
                    subtitleLine(for: item)
                }
                Spacer()
                if let progress = progress(for: item) {
                    DownloadProgressRing(progress: progress)
                        .frame(width: 28, height: 28)
                } else if item.status == .downloading || item.status == .queued {
                    // See `DownloadButton.isPreparing`'s doc comment — no
                    // byte progress yet, but a plain spinner beats blank
                    // space.
                    ProgressView().controlSize(.small)
                }
            }
        case .show(_, let seriesTitle, let posterImagePath, let episodeCount):
            HStack(spacing: 12) {
                thumbnail(relativePath: posterImagePath)
                VStack(alignment: .leading, spacing: 2) {
                    Text(seriesTitle).lineLimit(1)
                    Text("\(episodeCount) Episodes").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
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
            Text("Download Failed").font(.caption).foregroundStyle(.red)
        case .paused:
            Text("Paused").font(.caption).foregroundStyle(.secondary)
        case .completed:
            if item.kind == .episode {
                // "S1:E4 · Episode Name" — same pattern as
                // `MediaItem.railSubtitle`'s episode case.
                Text(item.episodeLabel.map { "\($0) \u{00B7} \(item.title)" } ?? item.title)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func thumbnail(relativePath: String?) -> some View {
        LocalFileImage(url: relativePath.map(DownloadFileStore.url(forRelativePath:)), targetSize: CGSize(width: 44, height: 66))
            .frame(width: 44, height: 66)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
