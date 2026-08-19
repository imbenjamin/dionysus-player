import SwiftUI

/// A show's downloaded episodes — grouped into season folders only if more
/// than one season is actually downloaded (matching "grouped by season if
/// necessary" literally); a show with episodes from just one season skips
/// straight to a flat, episode-number-sorted list instead, same
/// collapse-the-pointless-level reasoning `DownloadsView`'s own standalone-
/// vs-group split uses. Self-cleans back to the previous screen once its
/// last episode is deleted.
struct DownloadedShowView: View {
    let seriesID: String
    let downloadManager: DownloadManager

    @Environment(\.dismiss) private var dismiss
    @State private var episodes: [DownloadedItem] = []

    private var seasonIDs: Set<String> {
        Set(episodes.compactMap(\.seasonID))
    }

    private var sortedEpisodes: [DownloadedItem] {
        episodes.sorted { ($0.episodeNumber ?? 0) < ($1.episodeNumber ?? 0) }
    }

    var body: some View {
        List {
            if seasonIDs.count > 1 {
                ForEach(seasonRows, id: \.seasonID) { row in
                    NavigationLink(value: AppRoute.downloadedSeason(seriesID: seriesID, seasonID: row.seasonID)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title)
                            Text("\(row.count) Episodes").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                ForEach(sortedEpisodes) { episode in
                    DownloadedEpisodeRow(episode: episode, downloadManager: downloadManager)
                        .swipeActions {
                            Button("Delete", role: .destructive) { delete(episode) }
                        }
                }
            }
        }
        .navigationTitle(episodes.first?.seriesTitle ?? String(localized: "Show"))
        .onAppear(perform: refresh)
    }

    private struct SeasonRow { let seasonID: String; let title: String; let count: Int }
    private var seasonRows: [SeasonRow] {
        Dictionary(grouping: episodes) { $0.seasonID ?? "" }
            .map { seasonID, items in
                SeasonRow(
                    seasonID: seasonID,
                    title: items.first?.seasonNumber.map { String(localized: "Season \($0)") } ?? String(localized: "Season"),
                    count: items.count
                )
            }
            .sorted { ($0.title) < ($1.title) }
    }

    private func refresh() {
        episodes = downloadManager.store.visibleItems().filter { $0.seriesID == seriesID }
        if episodes.isEmpty { dismiss() }
    }

    private func delete(_ episode: DownloadedItem) {
        downloadManager.delete(itemID: episode.itemID)
        refresh()
    }
}

/// A single downloaded episode row — shared by `DownloadedShowView`'s
/// single-season flat list and `DownloadedSeasonView`.
struct DownloadedEpisodeRow: View {
    let episode: DownloadedItem
    let downloadManager: DownloadManager

    private var progress: DownloadProgress? {
        guard episode.status == .downloading || episode.status == .queued else { return nil }
        return downloadManager.activeDownloads[episode.itemID]
    }

    var body: some View {
        NavigationLink(value: AppRoute.downloadedAsset(itemID: episode.itemID)) {
            HStack(spacing: 12) {
                LocalFileImage(url: (episode.thumbImagePath ?? episode.posterImagePath).map(DownloadFileStore.url(forRelativePath:)))
                    .frame(width: 88, height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                VStack(alignment: .leading, spacing: 2) {
                    if let episodeLabel = episode.episodeLabel {
                        Text(episodeLabel).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(episode.title).lineLimit(1)
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
    }

    @ViewBuilder
    private var statusLine: some View {
        switch episode.status {
        case .downloading, .queued:
            if let progress {
                Text(progress.statusText).font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Downloading…").font(.caption2).foregroundStyle(.secondary)
            }
        case .failed:
            Text("Download Failed").font(.caption2).foregroundStyle(.red)
        case .paused:
            Text("Paused").font(.caption2).foregroundStyle(.secondary)
        case .completed:
            EmptyView()
        }
    }
}
