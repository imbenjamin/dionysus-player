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

    /// The video stream of whichever `MediaSourceInfo` `start()` resolved to
    /// — Jellyfin's own server-side probe result for it (`MediaStream
    /// .videoRangeType` in particular), used by `PlaybackStatsOverlay` to
    /// show a Dolby Vision source's base/enhancement layer format alongside
    /// AetherEngine's own `sourceColorFormat`. Set once in `start()`; `nil`
    /// before that resolves or if the source genuinely has no video stream.
    private(set) var sourceVideoStream: MediaStream?
    /// The Jellyfin server's own version string (e.g. "10.9.7"). Fetched
    /// lazily via `refreshServerVersion()` rather than in `start()` — it's
    /// diagnostics-only (`PlaybackStatsOverlay`'s Streaming section), so
    /// there's no reason to add a network round-trip to playback startup
    /// for it.
    private(set) var serverVersion: String?
    /// The live session Jellyfin's server is tracking for this device —
    /// refreshed periodically by `PlaybackStatsOverlay` while visible via
    /// `refreshStreamingSession()`. `nil` until the first successful fetch.
    private(set) var streamingSession: SessionInfoDto?

    private let client: JellyfinAPIClient
    private let userID: String
    private var progressReportTask: Task<Void, Never>?

    var audioTracks: [PlaybackTrack] { engine.audioTracks }
    var subtitleTracks: [PlaybackTrack] { engine.subtitleTracks }
    var videoFormatDescription: String? { engine.videoFormatDescription }
    /// A fresh snapshot on every access — see `PlaybackStats`. Intentionally
    /// not cached on the view model itself: `PlaybackStatsOverlay` polls
    /// this on its own timer only while it's actually visible, so there's
    /// nothing to keep in sync the rest of the time.
    var stats: PlaybackStats { engine.stats }

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
            sourceVideoStream = source?.mediaStreams?.first { $0.type == "Video" }

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

    func setZoomMode(_ mode: VideoZoomMode) {
        engine.zoomMode = mode
    }

    /// Fetches `serverVersion` once and caches it — safe to call on every
    /// `PlaybackStatsOverlay` poll tick since it short-circuits once already
    /// set, rather than re-fetching a value that can't change mid-session.
    func refreshServerVersion() async {
        guard serverVersion == nil else { return }
        serverVersion = try? await client.publicSystemInfo().version
    }

    /// Refreshes `streamingSession` from the server's own live view of this
    /// device's playback session — see that property's doc comment. Leaves
    /// the last known value on screen on failure rather than blanking the
    /// overlay's Streaming section over one dropped request.
    func refreshStreamingSession() async {
        if let session = try? await client.currentSession(deviceID: DeviceIdentity.deviceID) {
            streamingSession = session
        }
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
