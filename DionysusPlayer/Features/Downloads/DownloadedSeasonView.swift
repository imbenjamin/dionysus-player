import SwiftUI

/// One season's downloaded episodes — only ever pushed from
/// `DownloadedShowView` when that show has episodes downloaded from more
/// than one season. Flat list, sorted by episode number; self-cleans back
/// once its last episode is deleted, same as `DownloadedShowView`.
struct DownloadedSeasonView: View {
    let seriesID: String
    let seasonID: String
    let downloadManager: DownloadManager

    @Environment(\.dismiss) private var dismiss
    @State private var episodes: [DownloadedItem] = []

    private var sortedEpisodes: [DownloadedItem] {
        episodes.sorted { ($0.episodeNumber ?? 0) < ($1.episodeNumber ?? 0) }
    }

    var body: some View {
        List {
            ForEach(sortedEpisodes) { episode in
                DownloadedEpisodeRow(episode: episode, downloadManager: downloadManager)
                    .swipeActions {
                        Button("Delete", role: .destructive) { delete(episode) }
                    }
            }
        }
        .navigationTitle(episodes.first?.seasonNumber.map { String(localized: "Season \($0)") } ?? String(localized: "Season"))
        .onAppear(perform: refresh)
    }

    private func refresh() {
        episodes = downloadManager.store.visibleItems().filter { $0.seriesID == seriesID && $0.seasonID == seasonID }
        if episodes.isEmpty { dismiss() }
    }

    private func delete(_ episode: DownloadedItem) {
        downloadManager.delete(itemID: episode.itemID)
        refresh()
    }
}
