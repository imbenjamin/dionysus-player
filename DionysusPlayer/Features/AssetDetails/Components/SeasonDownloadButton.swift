import SwiftUI

/// Downloads every episode of one season that isn't already downloaded (or
/// re-attempts one that previously failed) — placed next to
/// `SeasonEpisodeList`'s season picker (or in its place, for a single-season
/// show). Unlike the single-item `DownloadButton`, this never prompts:
/// bulk-queuing N episodes can't reasonably ask an audio-track/subtitle
/// question per episode, so it auto-picks each episode's own default audio
/// track (falling back to its first) and downloads anyway when the default
/// subtitle track would be missing (the same "skippedSubtitleTracks" note
/// `DownloadedAssetDetailView` already surfaces per item covers that case
/// without needing an upfront warning here).
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

    /// An episode with no row at all, or one whose previous attempt
    /// failed — both are worth (re-)downloading. An episode already
    /// `.queued`/`.downloading`/`.completed` is left alone.
    private var missingEpisodes: [MediaItem] {
        episodes.filter { episode in
            let status = downloadManager.store.item(itemID: episode.id)?.status
            return status == nil || status == .failed
        }
    }

    private var isAnyInProgress: Bool {
        episodes.contains {
            let status = downloadManager.store.item(itemID: $0.id)?.status
            return status == .downloading || status == .queued
        }
    }

    private var isFullyDownloaded: Bool {
        !episodes.isEmpty && missingEpisodes.isEmpty && !isAnyInProgress
    }

    /// Combined byte progress across every episode of this season
    /// currently downloading/queued — `nil` when none are (so `body` falls
    /// back to a plain spinner rather than an empty ring), which also
    /// covers the very first moment after tapping, before any episode has
    /// its own row yet. An episode that hasn't started reporting real
    /// bytes yet (`DownloadButton.isPreparing`'s own "preparing" window)
    /// still contributes its own estimated total to the denominator —
    /// otherwise the ring would jump backward as each new episode's
    /// download actually starts and enlarges the season's overall total.
    private var aggregateProgress: DownloadProgress? {
        var totalDownloaded: Int64 = 0
        var totalExpected: Int64 = 0
        for episode in episodes {
            guard let row = downloadManager.store.item(itemID: episode.id),
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
        // Plain, not `.borderedProminent` — this sits directly beside the
        // season `Picker`, which is itself just tinted text/a chevron with
        // no background chip; matching that weight (rather than
        // `DownloadButton`'s own heavier chrome, which read as too heavy
        // here — confirmed live, 2026-08-19) is what makes this read as a
        // peer of the picker instead of a competing, more important-looking
        // control.
        Button(action: startBulkDownload) {
            Group {
                if let aggregateProgress {
                    DownloadProgressRing(progress: aggregateProgress)
                } else if isQueuing || isAnyInProgress {
                    // Nothing to show a ring for yet — either just tapped
                    // (no row exists for any episode yet) or every
                    // in-progress episode is still in its own "preparing"
                    // window with no estimated total to fall back to
                    // either (missing runtime/bitrate metadata).
                    ProgressView()
                        .tint(Color.dionysusPrimary)
                } else if isFullyDownloaded {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.dionysusPrimary)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(Color.dionysusPrimary)
                }
            }
            .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .disabled(isQueuing || isAnyInProgress || missingEpisodes.isEmpty)
        .alert("Couldn't Download Season", isPresented: $isShowingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    private func startBulkDownload() {
        guard !isQueuing else { return }
        isQueuing = true
        Task {
            defer { isQueuing = false }
            var failureCount = 0
            for episode in missingEpisodes {
                do {
                    let info = try await client.playbackInfo(itemID: episode.id, userID: userID)
                    guard let mediaSource = info.mediaSources?.first else {
                        failureCount += 1
                        continue
                    }
                    let streams = mediaSource.mediaStreams ?? []
                    let audioTrack = streams.first { $0.type == "Audio" && $0.isDefault == true }
                        ?? streams.first { $0.type == "Audio" }
                    let subtitleTracks = streams.filter { $0.type == "Subtitle" }
                    try await downloadManager.enqueue(
                        item: episode, mediaSource: mediaSource, audioTrack: audioTrack, subtitleTracks: subtitleTracks,
                        resolution: preferences.resolution, preset: preferences.bitratePreset,
                        client: client, userID: userID
                    )
                } catch {
                    // Best-effort: one episode failing to resolve/enqueue
                    // shouldn't stop the rest of the season from queuing.
                    failureCount += 1
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
