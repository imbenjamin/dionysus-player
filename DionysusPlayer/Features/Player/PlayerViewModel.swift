import Foundation
import Observation

@MainActor
@Observable
final class PlayerViewModel {
    private(set) var state: PlaybackState = .idle
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var item: MediaItem?
    private(set) var errorMessage: String?

    let engine: PlaybackEngine
    let itemID: String
    let startFromBeginning: Bool
    /// The version requested by the caller (`PlaybackRequest.mediaSourceID`
    /// — either the version-choice prompt's answer, or a remembered
    /// preference for a Resume). `nil` lets `start()` fall back to the
    /// server's own default, same as before this existed.
    let requestedMediaSourceID: String?

    /// Which version `start()` actually ended up playing — `source?.id`
    /// resolved from `playbackInfo`, which is `requestedMediaSourceID` when
    /// that matched one of the item's sources, otherwise the server's own
    /// default. Reported alongside every progress/stop call so the active
    /// session reflects the real file being streamed, not just what was
    /// asked for.
    private(set) var activeMediaSourceID: String?

    private let client: JellyfinAPIClient
    private let userID: String
    private var progressReportTask: Task<Void, Never>?

    var audioTracks: [PlaybackTrack] { engine.audioTracks }
    var subtitleTracks: [PlaybackTrack] { engine.subtitleTracks }
    var videoFormatDescription: String? { engine.videoFormatDescription }

    init(
        client: JellyfinAPIClient, userID: String, itemID: String, engine: PlaybackEngine,
        startFromBeginning: Bool = false, mediaSourceID: String? = nil
    ) {
        self.client = client
        self.userID = userID
        self.itemID = itemID
        self.engine = engine
        self.startFromBeginning = startFromBeginning
        self.requestedMediaSourceID = mediaSourceID

        engine.onStateChange = { [weak self] state in self?.state = state }
        engine.onTimeUpdate = { [weak self] time, duration in
            self?.currentTime = time
            self?.duration = duration
        }
    }

    func start() async {
        do {
            let images = await client.makeImageURLBuilder()
            let dto = try await client.item(userID: userID, itemID: itemID)
            let mediaItem = MediaItem(dto: dto, images: images)
            item = mediaItem

            let playbackInfo = try await client.playbackInfo(itemID: itemID, userID: userID, mediaSourceID: requestedMediaSourceID)
            // The requested id might not match anything (stale preference
            // for a version since removed from the server, say) — fall back
            // to the server's own default rather than failing outright.
            let source = requestedMediaSourceID.flatMap { id in playbackInfo.mediaSources?.first { $0.id == id } }
                ?? playbackInfo.mediaSources?.first
            activeMediaSourceID = source?.id

            guard let url = await client.streamURL(itemID: itemID, mediaSourceID: source?.id, container: source?.container) else {
                errorMessage = String(localized: "Couldn't build a playback URL for this item.")
                return
            }

            try await engine.load(url: url)
            if !startFromBeginning, let resumeSeconds = mediaItem.resumePositionSeconds, resumeSeconds > 0 {
                await engine.seek(to: resumeSeconds)
            }
            engine.play()

            try? await client.reportPlaybackStart(itemID: itemID, mediaSourceID: activeMediaSourceID)
            startProgressReporting()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? String(localized: "Playback failed to start.")
        }
    }

    func togglePlayPause() {
        engine.togglePlayPause()
    }

    func seek(to time: TimeInterval) {
        Task { await engine.seek(to: time) }
    }

    func selectAudioTrack(id: Int) {
        engine.selectAudioTrack(id: id)
    }

    func selectSubtitleTrack(id: Int?) {
        engine.selectSubtitleTrack(id: id)
    }

    func stop() async {
        progressReportTask?.cancel()
        let ticks = Int64(currentTime * 10_000_000)
        engine.stop()
        try? await client.reportPlaybackStopped(itemID: itemID, positionTicks: ticks, mediaSourceID: activeMediaSourceID)
    }

    private func startProgressReporting() {
        progressReportTask?.cancel()
        progressReportTask = Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let self else { return }
                let ticks = Int64(self.currentTime * 10_000_000)
                let isPaused = self.state == .paused
                try? await self.client.reportPlaybackProgress(
                    itemID: self.itemID, positionTicks: ticks, isPaused: isPaused, mediaSourceID: self.activeMediaSourceID
                )
            }
        }
    }
}
