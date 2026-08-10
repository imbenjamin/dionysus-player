import SwiftUI

/// Season picker (when there's more than one) plus that season's episode
/// list, for `ShowDetailView`.
struct SeasonEpisodeList: View {
    let seriesID: String
    let seasons: [MediaItem]
    @Binding var selectedSeasonID: String?
    /// The episode currently being displayed as this page's own content
    /// (`ShowDetailView`'s episode-content case — see that view's doc
    /// comment), if any — highlighted in the list below so it's clear which
    /// row the rest of the page is about. `nil` for ordinary Show/Season
    /// browsing, where no single episode is "the" content.
    var currentEpisodeID: String?
    var onSelectEpisode: (String) -> Void

    @Environment(AppState.self) private var appState
    @State private var episodes: [MediaItem] = []
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Episodes")
                    .font(.title3.bold())

                Spacer()

                if seasons.count > 1 {
                    Picker("Season", selection: $selectedSeasonID) {
                        ForEach(seasons) { season in
                            Text(season.name).tag(Optional(season.id))
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            .padding(.horizontal)

            if isLoading {
                LoadingView().frame(height: 120)
            } else {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(episodes) { episode in
                        EpisodeRow(episode: episode, isCurrent: episode.id == currentEpisodeID) {
                            onSelectEpisode(episode.id)
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
        .task(id: selectedSeasonID) { await loadEpisodes() }
    }

    private func loadEpisodes() async {
        guard let seasonID = selectedSeasonID,
              let client = appState.apiClient,
              let userID = appState.currentUser?.id else { return }

        isLoading = true
        defer { isLoading = false }
        do {
            let images = await client.makeImageURLBuilder()
            let result = try await client.episodes(seriesID: seriesID, seasonID: seasonID, userID: userID)
            episodes = result.items.map { MediaItem(dto: $0, images: images) }
        } catch {
            episodes = []
        }
    }
}

private struct EpisodeRow: View {
    let episode: MediaItem
    /// True for the episode `ShowDetailView` is currently showing as its own
    /// content (see `SeasonEpisodeList.currentEpisodeID`'s doc comment) —
    /// otherwise identical to any other row, just with a highlight so it's
    /// clear which one the rest of the page is about.
    var isCurrent: Bool = false
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                // A thin accent bar rather than a full-row background/inset —
                // keeps every other row's layout pixel-identical to before
                // this existed, rather than only the highlighted row shifting.
                RoundedRectangle(cornerRadius: 2)
                    .fill(isCurrent ? Color.dionysusPrimary : .clear)
                    .frame(width: 3)

                AsyncRemoteImage(url: episode.imageURL(type: "Primary", maxWidth: 300))
                    .frame(width: 160, height: 90)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 4) {
                    Text(episode.episodeLabel.map { "\($0)  \(episode.name)" } ?? episode.name)
                        .font(.subheadline.bold())
                        .foregroundStyle(isCurrent ? Color.dionysusPrimary : .primary)
                        .lineLimit(2)

                    if let duration = episode.durationText {
                        Text(duration)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let overview = episode.overview {
                        Text(overview)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }
}
