import SwiftUI

/// Season picker (when there's more than one) plus that season's episode
/// list, for `ShowDetailView`.
struct SeasonEpisodeList: View {
    let seriesID: String
    let seasons: [MediaItem]
    @Binding var selectedSeasonID: String?
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
                        EpisodeRow(episode: episode) {
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
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                AsyncRemoteImage(url: episode.imageURL(type: "Primary", maxWidth: 300))
                    .frame(width: 160, height: 90)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 4) {
                    Text(episode.episodeLabel.map { "\($0)  \(episode.name)" } ?? episode.name)
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)
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
