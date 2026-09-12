import SwiftUI

/// Downloads every episode of one season that isn't already downloaded (or
/// re-attempts one that previously failed) — placed next to
/// `SeasonEpisodeList`'s season picker (or in its place, for a single-season
/// show). Unlike the single-item `DownloadButton`, this never prompts:
/// bulk-queuing N episodes can't ask an audio-track/subtitle question per
/// episode, so it auto-picks each episode's default audio track (falling
/// back to its first) and downloads anyway when the default subtitle track
/// is missing — `DownloadedAssetDetailView`'s `skippedSubtitleTracks`
/// surfaces that per item.
struct SeasonDownloadButton: View {
    let seriesID: String
    let seasonID: String
    /// The season's own episodes, as already loaded by `SeasonEpisodeList`
    /// — this doesn't fetch its own copy.
    let episodes: [MediaItem]
    let client: JellyfinAPIClient
    let userID: String
    let downloadManager: DownloadManager

    private let preferences = DownloadPreferencesStore()

    @State private var isQueuing = false
    @State private var isShowingError = false
    @State private var errorMessage = ""

    /// One batched SwiftData fetch for every episode in this season, keyed
    /// by itemID — `body` fetches this once and threads it through the
    /// parameterized forms of `missingEpisodes`/`isAnyInProgress`/
    /// `isFullyDownloaded`/`aggregateProgress` instead of querying per
    /// episode. The plain zero-arg `missingEpisodes` survives for
    /// `startBulkDownload()`, which runs after the tap and needs a fresh
    /// re-fetch rather than a stale render-time snapshot.
    private var rowsByEpisodeID: [String: DownloadedItem] {
        // Reads `changeCount` to stay an Observation-tracked dependency —
        // `store.items(itemIDs:)` itself is a raw SwiftData fetch.
        _ = downloadManager.store.changeCount
        return Dictionary(uniqueKeysWithValues: downloadManager.store.items(itemIDs: Set(episodes.map(\.id))).map { ($0.itemID, $0) })
    }

    /// An episode with no row at all, or one whose previous attempt
    /// failed — both are worth (re-)downloading. An episode already
    /// `.queued`/`.downloading`/`.completed` is left alone.
    private func missingEpisodes(in rows: [String: DownloadedItem]) -> [MediaItem] {
        episodes.filter { episode in
            let status = rows[episode.id]?.status
            return status == nil || status == .failed
        }
    }
    private var missingEpisodes: [MediaItem] { missingEpisodes(in: rowsByEpisodeID) }

    private func isAnyInProgress(in rows: [String: DownloadedItem]) -> Bool {
        episodes.contains {
            let status = rows[$0.id]?.status
            return status == .downloading || status == .queued
        }
    }

    private func isFullyDownloaded(in rows: [String: DownloadedItem]) -> Bool {
        !episodes.isEmpty && missingEpisodes(in: rows).isEmpty && !isAnyInProgress(in: rows)
    }

    /// Combined byte progress across every episode of this season
    /// currently downloading/queued — `nil` when none are, so `body` falls
    /// back to a plain spinner instead of an empty ring (also covers the
    /// moment right after tapping, before any episode has a row yet). An
    /// episode still in `DownloadButton.isPreparing`'s window contributes
    /// its estimated total to the denominator anyway, so the ring doesn't
    /// jump backward as each new episode starts and enlarges the total.
    private func aggregateProgress(in rows: [String: DownloadedItem]) -> DownloadProgress? {
        var totalDownloaded: Int64 = 0
        var totalExpected: Int64 = 0
        for episode in episodes {
            guard let row = rows[episode.id],
                  row.status == .downloading || row.status == .queued else { continue }
            if let live = downloadManager.activeDownloads[episode.id] {
                totalDownloaded += live.bytesDownloaded
                totalExpected += live.totalBytesExpected
            } else {
                totalExpected += row.estimatedTotalBytes ?? 0
            }
        }
        guard totalExpected > 0 else { return nil }
        return DownloadProgress(bytesDownloaded: totalDownloaded, totalBytesExpected: totalExpected)
    }

    var body: some View {
        let rows = rowsByEpisodeID
        // Not `.borderedProminent` — too heavy beside the season `Picker`,
        // but a bare icon under-reads as tappable. Splits the difference:
        // a filled circular badge in `dionysusPrimaryLight` (the Restart
        // button's "secondary but related" tint), with `.padding(8)`
        // around the icon for a larger tap target than the circle alone.
        Button(action: startBulkDownload) {
            Group {
                if let progress = aggregateProgress(in: rows) {
                    DownloadProgressRing(progress: progress)
                } else if isQueuing || isAnyInProgress(in: rows) {
                    // Nothing to show a ring for yet — either just tapped,
                    // or every in-progress episode is still in its own
                    // "preparing" window with no estimated total yet.
                    ProgressView()
                        .tint(Color.dionysusPrimary)
                } else if isFullyDownloaded(in: rows) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.dionysusPrimary)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(Color.dionysusPrimary)
                }
            }
            .frame(width: 20, height: 20)
            .padding(8)
            .background(Circle().fill(Color.dionysusPrimaryLight))
        }
        .buttonStyle(.plain)
        .disabled(isQueuing || isAnyInProgress(in: rows) || missingEpisodes(in: rows).isEmpty)
        .accessibilityLabel(accessibilityLabel(in: rows))
        .alert("Couldn't Download Season", isPresented: $isShowingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    /// Mirrors `body`'s own state icon selection above.
    private func accessibilityLabel(in rows: [String: DownloadedItem]) -> String {
        if let progress = aggregateProgress(in: rows) {
            return progress.statusText
        } else if isQueuing || isAnyInProgress(in: rows) {
            return String(localized: "Downloading Season")
        } else if isFullyDownloaded(in: rows) {
            return String(localized: "Season Downloaded")
        } else {
            return String(localized: "Download Season")
        }
    }

    private func startBulkDownload() {
        guard !isQueuing else { return }
        isQueuing = true
        Task {
            defer { isQueuing = false }
            let toDownload = missingEpisodes
            let client = client
            let userID = userID
            let downloadManager = downloadManager
            let resolution = preferences.resolution
            let preset = preferences.bitratePreset
            // Each episode's `DownloadManager.enqueue(...)` only inserts its
            // `DownloadedItem` row after its own `playbackInfo` round trip
            // resolves — awaiting episodes one at a time left every episode
            // after the first with no row until the one ahead finished its
            // entire enqueue (image/segment/trickplay/subtitle prep
            // included), undercounting an in-progress download. Bounded to
            // `maxConcurrentDownloads` so a large season doesn't fire every
            // episode's requests at the server at once; `nil` (Unlimited)
            // runs the whole season concurrently.
            let limit = max(1, preferences.maxConcurrentDownloads ?? toDownload.count)
            var failureCount = 0
            await withTaskGroup(of: Bool.self) { group in
                var nextIndex = 0
                func addNext() {
                    guard nextIndex < toDownload.count else { return }
                    let episode = toDownload[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        do {
                            let info = try await client.playbackInfo(itemID: episode.id, userID: userID)
                            guard let mediaSource = info.mediaSources?.first else { return false }
                            let streams = mediaSource.mediaStreams ?? []
                            let audioTrack = streams.first { $0.type == "Audio" && $0.isDefault == true }
                                ?? streams.first { $0.type == "Audio" }
                            let subtitleTracks = streams.filter { $0.type == "Subtitle" }
                            try await downloadManager.enqueue(
                                item: episode, mediaSource: mediaSource, audioTrack: audioTrack, subtitleTracks: subtitleTracks,
                                resolution: resolution, preset: preset,
                                client: client, userID: userID
                            )
                            return true
                        } catch {
                            // Best-effort: one episode failing to
                            // resolve/enqueue shouldn't stop the rest of the
                            // season from queuing.
                            return false
                        }
                    }
                }
                for _ in 0..<min(limit, toDownload.count) { addNext() }
                for await succeeded in group {
                    if !succeeded { failureCount += 1 }
                    addNext()
                }
            }
            if failureCount > 0 {
                errorMessage = failureCount == 1
                    ? String(localized: "1 episode couldn't be downloaded.")
                    : String(localized: "\(failureCount) episodes couldn't be downloaded.")
                isShowingError = true
            }
        }
    }
}
