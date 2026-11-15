import SwiftUI

/// Downloads every episode of one season that isn't already downloaded (or
/// re-attempts one that previously failed) — placed next to
/// `SeasonEpisodeList`'s season picker (or in its place, for a single-season
/// show). Unlike the single-item `DownloadButton`, this never asks about
/// tracks: bulk-queuing N episodes can't ask an audio-track/subtitle question
/// per episode, so it auto-picks each episode's default audio track (falling
/// back to its first) and downloads anyway when the default subtitle track
/// is missing — `DownloadedAssetDetailView`'s `skippedSubtitleTracks`
/// surfaces that per item.
///
/// It does ask about versions (#289), at most once per tap:
/// `SeasonDownloadCoordinator` scans the season first, then this asks once
/// when every episode with versions has the same ones, shows
/// `BulkVersionChoiceSheet` when they differ, and asks nothing when no
/// episode has more than one.
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

    /// The current run's, made fresh per tap (nil before the first).
    @State private var coordinator: SeasonDownloadCoordinator?
    @State private var isAskingUniform = false
    @State private var uniformLabels: [String] = []
    @State private var isAskingPerEpisode = false
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

    /// A run is under way, a question included: the button can't start
    /// another.
    private var isBusy: Bool { (coordinator?.phase ?? .idle) != .idle }

    /// Scanning or queuing, when the button shows a spinner; not while a
    /// question waits, when it keeps its arrow.
    private var isWorking: Bool {
        switch coordinator?.phase {
        case .scanning, .queuing: true
        default: false
        }
    }

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
        // The same neutral circle as the page-level `DownloadButton`, one size
        // down so it sits level with the season `Picker`'s text.
        Button(action: startBulkDownload) {
            Group {
                if let progress = aggregateProgress(in: rows) {
                    DownloadProgressRing(progress: progress, tint: .primary)
                } else if isWorking || isAnyInProgress(in: rows) {
                    // Nothing to show a ring for yet — either just tapped,
                    // or every in-progress episode is still in its own
                    // "preparing" window with no estimated total yet.
                    ProgressView()
                } else if isFullyDownloaded(in: rows) {
                    Image(systemName: "checkmark")
                } else {
                    // Bare `arrow.down`: the button already draws the circle.
                    Image(systemName: "arrow.down")
                }
            }
            .frame(width: 20, height: 20)
        }
        .secondaryActionButtonStyle(controlSize: .regular)
        .disabled(isBusy || isAnyInProgress(in: rows) || missingEpisodes(in: rows).isEmpty)
        .accessibilityLabel(accessibilityLabel(in: rows))
        .accessibilityIdentifier(A11yID.AssetDetail.seasonDownloadButton)
        .onChange(of: coordinator?.phase, initial: true) { syncQuestions() }
        .onChange(of: isAskingUniform) { questionDismissed() }
        .onChange(of: isAskingPerEpisode) { questionDismissed() }
        // `SeasonEpisodeList` gives each season a button of its own
        // (`.id(seasonID)`), so picking another season ends this one: a scan
        // still running would otherwise ask, or download, under the next
        // season's button. A run already queuing finishes (see `cancel()`).
        .onDisappear { coordinator?.cancel() }
        // Anchored to this button, so on iPad its popover points at the tap.
        .confirmationDialog(
            "Download Season in Which Version?", isPresented: $isAskingUniform, titleVisibility: .visible
        ) {
            ForEach(Array(uniformLabels.enumerated()), id: \.offset) { index, label in
                // The server's own name for it, not localized.
                Button(label) { chooseUniform(label) }
                    .accessibilityIdentifier(A11yID.Versions.bulkOption(index))
            }
        }
        .sheet(isPresented: $isAskingPerEpisode) {
            if case .askingPerEpisode(let scans) = coordinator?.phase {
                let store = MediaVersionPreferenceStore()
                BulkVersionChoiceSheet(
                    scans: scans, episodeCount: coordinator?.scannedEpisodeCount ?? scans.count,
                    rememberedSourceID: { store.preferredMediaSourceID(forItem: $0, userID: userID) },
                    onDownload: choosePerEpisode,
                    onCancel: { isAskingPerEpisode = false }
                )
            }
        }
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
        } else if isWorking || isAnyInProgress(in: rows) {
            return String(localized: "Downloading Season")
        } else if isFullyDownloaded(in: rows) {
            return String(localized: "Season Downloaded")
        } else {
            return String(localized: "Download Season")
        }
    }

    private func startBulkDownload() {
        guard !isBusy else { return }
        let client = client
        let userID = userID
        let downloadManager = downloadManager
        let resolution = preferences.resolution
        let preset = preferences.bitratePreset
        let toDownload = missingEpisodes
        let coordinator = SeasonDownloadCoordinator(
            fetchSources: { itemID in
                try await client.playbackInfo(itemID: itemID, userID: userID).mediaSources ?? []
            },
            enqueue: { episode, mediaSource, versionLabel in
                // No prompt per episode: the default audio track (else the
                // first), and every subtitle track.
                let streams = mediaSource.mediaStreams ?? []
                let audioTrack = streams.first { $0.type == "Audio" && $0.isDefault == true }
                    ?? streams.first { $0.type == "Audio" }
                let subtitleTracks = streams.filter { $0.type == "Subtitle" }
                try await downloadManager.enqueue(
                    item: episode, mediaSource: mediaSource, versionLabel: versionLabel,
                    audioTrack: audioTrack, subtitleTracks: subtitleTracks,
                    resolution: resolution, preset: preset,
                    client: client, userID: userID
                )
            },
            isStillMissing: { itemID in
                // As `missingEpisodes` reads it, but now rather than at the tap.
                let status = downloadManager.store.item(itemID: itemID)?.status
                return status == nil || status == .failed
            }
        )
        self.coordinator = coordinator
        // Each episode's `DownloadManager.enqueue(...)` only inserts its
        // `DownloadedItem` row after its own requests resolve, so episodes
        // run side by side rather than one at a time (which left every
        // episode after the first with no row, undercounting the season).
        // Bounded to `maxConcurrentDownloads` so a large season doesn't fire
        // every episode's requests at the server at once; `nil` (Unlimited)
        // runs the whole season concurrently.
        let limit = max(1, preferences.maxConcurrentDownloads ?? toDownload.count)
        let run = coordinator.start(episodes: toDownload, limit: limit)
        Task {
            await run.value
            reportFailures(of: coordinator)
        }
    }

    private func chooseUniform(_ label: String) {
        guard let coordinator else { return }
        let run = coordinator.chooseUniform(label)
        Task {
            await run.value
            reportFailures(of: coordinator)
        }
    }

    private func choosePerEpisode(_ picks: [String: String]) {
        guard let coordinator else { return }
        let run = coordinator.choosePerEpisode(picks)
        Task {
            await run.value
            reportFailures(of: coordinator)
        }
    }

    /// Once a run has finished (not while it waits on a question): any
    /// episode that couldn't be scanned or queued, in one alert.
    private func reportFailures(of coordinator: SeasonDownloadCoordinator) {
        guard coordinator.phase == .idle, coordinator.failureCount > 0 else { return }
        let failureCount = coordinator.failureCount
        errorMessage = failureCount == 1
            ? String(localized: "1 episode couldn't be downloaded.")
            : String(localized: "\(failureCount) episodes couldn't be downloaded.")
        isShowingError = true
    }

    /// Follows the coordinator's phase into the two questions' presentation
    /// state. Plain `@State` flags rather than `Binding`s computed from the
    /// phase, which were unreliable as `confirmationDialog`'s `isPresented`
    /// across repeated presentations (see `versionChoiceDialog`).
    private func syncQuestions() {
        switch coordinator?.phase {
        case .askingUniform(let labels):
            uniformLabels = labels
            isAskingUniform = true
            isAskingPerEpisode = false
        case .askingPerEpisode:
            isAskingUniform = false
            isAskingPerEpisode = true
        default:
            isAskingUniform = false
            isAskingPerEpisode = false
        }
    }

    /// A question went away. An answer has already moved the phase on (its
    /// action runs before the dismissal is reported), so a phase still
    /// asking means Cancel, a tap outside or a swipe down: download nothing.
    private func questionDismissed() {
        switch coordinator?.phase {
        case .askingUniform where !isAskingUniform, .askingPerEpisode where !isAskingPerEpisode:
            coordinator?.cancel()
        default:
            break
        }
    }
}
