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

    private let client: JellyfinAPIClient
    private let userID: String
    private var progressReportTask: Task<Void, Never>?

    var audioTracks: [PlaybackTrack] { engine.audioTracks }
    var subtitleTracks: [PlaybackTrack] { engine.subtitleTracks }
    var videoFormatDescription: String? { engine.videoFormatDescription }

    init(client: JellyfinAPIClient, userID: String, itemID: String, engine: PlaybackEngine, startFromBeginning: Bool = false) {
        self.client = client
        self.userID = userID
        self.itemID = itemID
        self.engine = engine
        self.startFromBeginning = startFromBeginning

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

            let playbackInfo = try await client.playbackInfo(itemID: itemID, userID: userID)
            let source = playbackInfo.mediaSources?.first

            guard let url = await client.streamURL(itemID: itemID, mediaSourceID: source?.id, container: source?.container) else {
                errorMessage = String(localized: "Couldn't build a playback URL for this item.")
                return
            }

            try await engine.load(url: url)
            if !startFromBeginning, let resumeSeconds = mediaItem.resumePositionSeconds, resumeSeconds > 0 {
                await engine.seek(to: resumeSeconds)
            }
            engine.play()

            try? await client.reportPlaybackStart(itemID: itemID)
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
        try? await client.reportPlaybackStopped(itemID: itemID, positionTicks: ticks)
    }

    private func startProgressReporting() {
        progressReportTask?.cancel()
        progressReportTask = Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let self else { return }
                let ticks = Int64(self.currentTime * 10_000_000)
                let isPaused = self.state == .paused
                try? await self.client.reportPlaybackProgress(itemID: self.itemID, positionTicks: ticks, isPaused: isPaused)
            }
        }
    }
}
