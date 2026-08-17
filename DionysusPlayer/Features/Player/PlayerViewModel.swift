import CoreGraphics
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
    /// Decoded subtitle cues, unfiltered — covers a window ahead of the
    /// playhead, not just what's active now. `SubtitleOverlayView` filters
    /// this against `sourceTime` itself; see `SubtitleCueDisplay`'s doc
    /// comment for why filtering happens downstream rather than here.
    private(set) var subtitleCues: [SubtitleCueDisplay] = []
    /// Source-PTS playhead, the axis `subtitleCues` is stamped in — kept
    /// separate from `currentTime` (the item/AVPlayer clock `onTimeUpdate`
    /// reports) since the two can diverge across producer restarts.
    private(set) var sourceTime: TimeInterval = 0
    /// Drives the PiP button's enabled state — see
    /// `PlaybackEngine.onPictureInPicturePossibleChange`'s doc comment.
    private(set) var isPictureInPicturePossible = false
    /// While `true`, `PlayerView` shows a placeholder over the video surface
    /// instead of the live picture — see `PlaybackEngine
    /// .onPictureInPictureActiveChange`'s doc comment.
    private(set) var isPictureInPictureActive = false

    /// The episode immediately following this one, for the in-player "Up
    /// Next" prompt (`NextUpOverlay`) — `nil` for non-episode content, a
    /// series' last episode, or while the fire-and-forget lookup in
    /// `start()` hasn't resolved yet (or failed; see that method's doc
    /// comment). Resolved via `JellyfinAPIClient.nextEpisode(...)`, not
    /// `nextUp(...)` — see that method's own doc comment for why the latter
    /// can't answer "what's next" reliably mid-playback.
    private(set) var nextEpisode: MediaItem?
    /// Set by `dismissNextUp()` (the "Up Next" card's Cancel button) —
    /// once true, `nextUpSecondsRemaining` stays `nil` for the rest of this
    /// item's playback even if `currentTime` moves back inside the
    /// countdown window (e.g. the user scrubs backward), matching "cancel
    /// the whole automatic countdown" rather than just dismissing once.
    private(set) var isNextUpDismissed = false

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
    private let trackPreferenceStore: TrackPreferenceStore
    private let nextUpPreferenceStore: NextUpPreferenceStore
    private var progressReportTask: Task<Void, Never>?

    var audioTracks: [PlaybackTrack] { engine.audioTracks }
    var subtitleTracks: [PlaybackTrack] { engine.subtitleTracks }
    var videoFormatDescription: String? { engine.videoFormatDescription }
    var videoNaturalSize: CGSize? { engine.videoNaturalSize }
    /// A fresh snapshot on every access — see `PlaybackStats`. Intentionally
    /// not cached on the view model itself: `PlaybackStatsOverlay` polls
    /// this on its own timer only while it's actually visible, so there's
    /// nothing to keep in sync the rest of the time.
    var stats: PlaybackStats { engine.stats }

    /// The configured countdown length itself, for `NextUpOverlay`'s ring
    /// to compute a remaining-*fraction* from alongside
    /// `nextUpSecondsRemaining` — a plain elapsing count has no notion of
    /// its own starting point. A passthrough of `nextUpPreferenceStore
    /// .countdownSeconds`, same shape as `stats`/`audioTracks` above.
    var nextUpTotalCountdownSeconds: Int? { nextUpPreferenceStore.countdownSeconds }

    /// Seconds remaining before this episode ends, while the "Up Next"
    /// prompt should be showing — `nil` otherwise (no next episode
    /// resolved yet, the feature's off, dismissed for this session, or
    /// simply outside the countdown window). Derived purely from `duration`/
    /// `currentTime`, with no separate `Timer`/countdown `Task` of its own:
    /// `currentTime` already ticks ~10x/sec during playback via
    /// `onTimeUpdate` and holds steady while paused, so this value updates
    /// and freezes for free, the same way `sourceTime` does.
    ///
    /// Clamped to `0` rather than excluded once `remaining` reaches or
    /// passes it — confirmed live (2026-08-17) that `currentTime` doesn't
    /// reliably stop exactly at `duration`: the transport clock kept
    /// advancing past the item's real end even once it had stopped
    /// actually playing, which used to push `remaining` negative and fail
    /// an earlier `remaining > 0` guard here. That guard's intent (clear
    /// the prompt right at the real end rather than overlap with today's
    /// unchanged end-of-playback behavior) was correct, but excluding `0`
    /// meant this value could jump straight from `1` to `nil` and skip `0`
    /// entirely — silently breaking `PlayerView`'s `.onChange(of:
    /// nextUpSecondsRemaining)` auto-advance trigger, which only fires on
    /// an exact `0`. Reaching `advanceToNextEpisode()` (Play Now, or that
    /// auto-trigger) is itself what clears this prompt now, by tearing this
    /// `PlayerView` instance's content down, so there's no longer a reason
    /// to hide it early anyway.
    var nextUpSecondsRemaining: Int? {
        guard nextEpisode != nil, !isNextUpDismissed,
              let countdownSeconds = nextUpPreferenceStore.countdownSeconds,
              duration > 0 else { return nil }
        let remaining = duration - currentTime
        guard remaining <= Double(countdownSeconds) else { return nil }
        return max(0, Int(remaining.rounded(.up)))
    }

    init(
        client: JellyfinAPIClient, userID: String, itemID: String, engine: PlaybackEngine,
        startFromBeginning: Bool = false, mediaSourceID: String? = nil,
        trackPreferenceStore: TrackPreferenceStore = TrackPreferenceStore(),
        nextUpPreferenceStore: NextUpPreferenceStore = NextUpPreferenceStore()
    ) {
        self.client = client
        self.userID = userID
        self.itemID = itemID
        self.engine = engine
        self.startFromBeginning = startFromBeginning
        self.requestedMediaSourceID = mediaSourceID
        self.trackPreferenceStore = trackPreferenceStore
        self.nextUpPreferenceStore = nextUpPreferenceStore

        engine.onStateChange = { [weak self] state in self?.state = state }
        engine.onTimeUpdate = { [weak self] time, duration in
            self?.currentTime = time
            self?.duration = duration
        }
        engine.onSubtitleCuesChange = { [weak self] cues in self?.subtitleCues = cues }
        engine.onSourceTimeUpdate = { [weak self] sourceTime in self?.sourceTime = sourceTime }
        engine.onPictureInPicturePossibleChange = { [weak self] possible in self?.isPictureInPicturePossible = possible }
        engine.onPictureInPictureActiveChange = { [weak self] active in self?.isPictureInPictureActive = active }
    }

    func start() async {
        do {
            let images = await client.makeImageURLBuilder()
            let dto = try await client.item(userID: userID, itemID: itemID)
            let mediaItem = MediaItem(dto: dto, images: images)
            item = mediaItem
            // Title/subtitle land immediately so the lock screen/Control
            // Center have *something* as soon as this resolves — artwork
            // trails in separately once fetched (see
            // `loadNowPlayingArtwork(for:)`), rather than blocking on it.
            engine.setNowPlayingInfo(title: mediaItem.railTitle, subtitle: mediaItem.railSubtitle, artwork: nil)
            loadNowPlayingArtwork(for: mediaItem)
            loadNextEpisode(for: mediaItem, images: images)

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

            var externalSubtitles: [ExternalSubtitleSource] = []
            if let source, let mediaSourceID = source.id {
                externalSubtitles = await Self.externalSubtitleSources(
                    itemID: itemID, mediaSourceID: mediaSourceID, mediaStreams: source.mediaStreams ?? [], client: client
                )
            }
            let atmosAudioTrackIndices = Self.atmosAudioTrackIndices(from: source?.mediaStreams ?? [])

            try await engine.load(
                url: url, externalSubtitles: externalSubtitles, knownAtmosAudioTrackIndices: atmosAudioTrackIndices
            )
            applyStoredTrackSelection()
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

    /// Fire-and-forget: fetches the item's poster (if it has one) via
    /// `RemoteImageLoader` and re-stages the full Now Playing info with it
    /// once it resolves — title/subtitle already went in synchronously in
    /// `start()`, this only ever adds artwork on top. A failed/absent fetch
    /// just leaves Now Playing without artwork, same as before this ran;
    /// nothing here can fail `start()` itself.
    private func loadNowPlayingArtwork(for item: MediaItem) {
        guard let artworkURL = item.primaryImageURL else { return }
        Task { [weak self] in
            guard let image = try? await RemoteImageLoader.shared.image(for: artworkURL) else { return }
            self?.engine.setNowPlayingInfo(title: item.railTitle, subtitle: item.railSubtitle, artwork: image)
        }
    }

    /// Fire-and-forget, same shape as `loadNowPlayingArtwork(for:)`: resolves
    /// `nextEpisode` for the "Up Next" prompt via `JellyfinAPIClient
    /// .nextEpisode(...)` — see that method's doc comment for why this can't
    /// use `nextUp(...)` instead. A no-op for non-episode content or an
    /// episode DTO missing `seriesId`/`seasonId` (shouldn't happen in
    /// practice, but there's nothing to look up without them); a failed
    /// fetch just leaves `nextEpisode` `nil`, the same "bonus, not a
    /// requirement" treatment `start()` already gives external subtitles.
    private func loadNextEpisode(for item: MediaItem, images: ImageURLBuilder) {
        guard item.kind == .episode, let seriesID = item.dto.seriesId, let seasonID = item.dto.seasonId else { return }
        let userID = self.userID
        Task { [weak self] in
            guard let dto = try? await self?.client.nextEpisode(
                currentEpisodeID: item.id, seriesID: seriesID, seasonID: seasonID, userID: userID
            ) else { return }
            self?.nextEpisode = MediaItem(dto: dto, images: images)
        }
    }

    /// The "Up Next" prompt's Cancel button — see `isNextUpDismissed`'s doc
    /// comment for why this sticks for the rest of this item's playback
    /// rather than just hiding the card once.
    func dismissNextUp() {
        isNextUpDismissed = true
    }

    /// Maps the `isExternal == true` subtitle `MediaStream`s off a resolved
    /// `MediaSourceInfo` into `ExternalSubtitleSource`s AetherEngine can
    /// register alongside the load — see `ExternalSubtitleSource`'s doc
    /// comment and `JellyfinAPIClient.subtitleURL`'s for why the URL is
    /// built from `itemID`/`mediaSourceID`/`stream.index` rather than read
    /// off the stream itself. A URL `subtitleURL` can't resolve is skipped
    /// rather than failing the whole load; external subtitles are a bonus,
    /// not a requirement to play.
    static func externalSubtitleSources(
        itemID: String, mediaSourceID: String, mediaStreams: [MediaStream], client: JellyfinAPIClient
    ) async -> [ExternalSubtitleSource] {
        var sources: [ExternalSubtitleSource] = []
        for stream in mediaStreams where stream.type == "Subtitle" && stream.isExternal == true {
            guard let url = await client.subtitleURL(
                itemID: itemID, mediaSourceID: mediaSourceID, streamIndex: stream.index, codec: stream.codec
            ) else { continue }
            sources.append(ExternalSubtitleSource(
                url: url,
                name: stream.title,
                language: stream.language,
                isForced: stream.isForced ?? false,
                isHearingImpaired: stream.isHearingImpaired ?? false,
                isDefault: stream.isDefault ?? false,
                formatHint: stream.codec
            ))
        }
        return sources
    }

    /// Audio track indices Jellyfin's own server-side probe flagged
    /// `audioSpatialFormat == "DolbyAtmos"` — forwarded to the engine as
    /// `knownAtmosAudioTrackIndices` so the picker can show an "Atmos" flag
    /// for a track AetherEngine itself has no way to detect as such
    /// (TrueHD's Atmos extension — see `PlaybackEngine.load(url:
    /// externalSubtitles:knownAtmosAudioTrackIndices:)`'s doc comment).
    /// Deliberately reads this field rather than text-matching the
    /// stream's codec/title — `audioSpatialFormat`'s own doc comment
    /// calls that out as the *less* reliable way to detect Atmos.
    ///
    /// Returns *physical* indices (matching AetherEngine's `TrackInfo.id`/
    /// `PlaybackTrack.id`), NOT `MediaStream.index` verbatim: confirmed
    /// live (2026-08-14) that Jellyfin numbers external (`isExternal ==
    /// true`) streams into the same index sequence as embedded ones even
    /// though they carry no bytes in the physical container AetherEngine
    /// actually demuxes — a Saving Private Ryan source with one external
    /// subtitle at index 0 reported every embedded audio stream's index
    /// one higher than AetherEngine's own numbering for the identical
    /// tracks (2/3/4 vs. AetherEngine's 1/2/3). Subtracting, for each
    /// stream, the count of external streams whose index precedes it
    /// recovers the physical index.
    static func atmosAudioTrackIndices(from mediaStreams: [MediaStream]) -> Set<Int> {
        let externalIndices = mediaStreams.filter { $0.isExternal == true }.map(\.index)
        func physicalIndex(_ index: Int) -> Int {
            index - externalIndices.filter { $0 < index }.count
        }
        return Set(mediaStreams
            .filter { $0.type == "Audio" && $0.audioSpatialFormat == "DolbyAtmos" }
            .map { physicalIndex($0.index) })
    }

    /// Restores the audio/subtitle tracks the user last explicitly picked
    /// for this item (`TrackPreferenceStore`), overriding whatever
    /// `engine.load(...)` just defaulted to — including
    /// `AetherPlaybackEngine`'s own forced-subtitle auto-select, which
    /// documents itself as a one-time default a later explicit selection
    /// (`selectSubtitleTrack(id:)`) is expected to override. Does nothing
    /// when there's no stored preference at all (a fresh item, or one never
    /// explicitly touched), leaving that default selection exactly as-is.
    ///
    /// A stored track is only restored when a track with the *same id and
    /// title* still exists in the freshly loaded list — id alone isn't
    /// enough (see `TrackPreferenceStore.TrackChoice`'s doc comment: track
    /// ids are physical container positions, so the same id can silently
    /// point at a different track if the layout changed). Anything that
    /// doesn't match is skipped rather than passed through: same "fall back
    /// gracefully rather than fail" treatment as `requestedMediaSourceID`
    /// above.
    private func applyStoredTrackSelection() {
        guard let selection = trackPreferenceStore.selection(forItem: itemID, userID: userID) else { return }
        if let audioTrack = selection.audioTrack,
           engine.audioTracks.contains(where: { $0.id == audioTrack.id && $0.title == audioTrack.title }) {
            engine.selectAudioTrack(id: audioTrack.id)
        }
        switch selection.subtitlePreference {
        case .unset:
            break
        case .off:
            engine.selectSubtitleTrack(id: nil)
        case .track(let subtitleTrack):
            if engine.subtitleTracks.contains(where: { $0.id == subtitleTrack.id && $0.title == subtitleTrack.title }) {
                engine.selectSubtitleTrack(id: subtitleTrack.id)
            }
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
        guard let track = engine.audioTracks.first(where: { $0.id == id }) else { return }
        trackPreferenceStore.recordAudioSelection(
            TrackPreferenceStore.TrackChoice(id: track.id, title: track.title), forItem: itemID, userID: userID
        )
    }

    func selectSubtitleTrack(id: Int?) {
        engine.selectSubtitleTrack(id: id)
        guard let id else {
            trackPreferenceStore.recordSubtitleSelection(nil, forItem: itemID, userID: userID)
            return
        }
        guard let track = engine.subtitleTracks.first(where: { $0.id == id }) else { return }
        trackPreferenceStore.recordSubtitleSelection(
            TrackPreferenceStore.TrackChoice(id: track.id, title: track.title), forItem: itemID, userID: userID
        )
    }

    func setZoomMode(_ mode: VideoZoomMode) {
        engine.zoomMode = mode
    }

    func startPictureInPicture() {
        engine.startPictureInPicture()
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
