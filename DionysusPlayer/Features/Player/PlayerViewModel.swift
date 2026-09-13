import CoreGraphics
import Foundation
import Observation
import os

@MainActor
@Observable
final class PlayerViewModel {
    private static let logger = Logger(subsystem: "com.dionysus.player", category: "PlayerViewModel")

    private(set) var state: PlaybackState = .idle
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var item: MediaItem?
    /// The offline path's local-file logo, set only by `startOffline`.
    /// `item.logoImageURL` is structurally `nil` there — the synthetic
    /// `BaseItemDto` carries no `imageTags` — so `PlayerControlsOverlay.titleRow`
    /// checks this first. `nil` on the live path, and for an offline item with no
    /// downloaded logo, which falls back to title text.
    private(set) var offlineLogoURL: URL?
    private(set) var errorMessage: String?
    /// What recovery `errorMessage` allows; `nil` exactly when it is. Drives
    /// `PlayerView`'s Retry-versus-Close branch.
    private(set) var failureCategory: PlaybackFailure.Category?
    /// Decoded subtitle cues, unfiltered: a window ahead of the playhead, not
    /// only what is active. `SubtitleOverlayView` filters against `sourceTime`.
    private(set) var subtitleCues: [SubtitleCueDisplay] = []
    /// The source-PTS playhead `subtitleCues` are stamped against, separate from
    /// `currentTime`'s AVPlayer clock, which diverges across producer restarts.
    private(set) var sourceTime: TimeInterval = 0
    /// Drives the PiP button's enabled state.
    private(set) var isPictureInPicturePossible = false
    /// While `true`, `PlayerView` shows a placeholder over the video surface.
    private(set) var isPictureInPictureActive = false

    /// The item following this one, for `NextUpOverlay`. `nil` until the
    /// fire-and-forget lookup in `start()` resolves, and once there is nothing
    /// left to play.
    ///
    /// `loadNextUpItem(for:images:)` resolves it two ways. With a non-empty
    /// `playbackQueue` it is the next member — a local lookup, no network call,
    /// and not restricted to episodes, since a Playlist's next member can be a
    /// Movie. Otherwise, for an episode, `JellyfinAPIClient.nextEpisode(...)`
    /// rather than `nextUp(...)`, which can't answer this reliably mid-playback.
    private(set) var nextEpisode: MediaItem?
    /// Set by the Up Next card's Cancel button. Once true,
    /// `nextUpSecondsRemaining` stays `nil` for the rest of this item's playback
    /// even if a backward scrub re-enters the countdown window — cancelling the
    /// countdown rather than dismissing once.
    private(set) var isNextUpDismissed = false

    /// Skippable time ranges, fetched fire-and-forget in `start()` alongside
    /// `nextEpisode`. Empty rather than `nil` both before that resolves and when
    /// there are none; nothing downstream distinguishes the two.
    private(set) var mediaSegments: [PlaybackSegment] = []

    /// Chapter markers driving the segmented scrubber, magnetic snap,
    /// current-chapter button and picker. Unlike `mediaSegments`, these ride
    /// along on the item DTO `start()` already fetches, so they are set
    /// synchronously with `item`. Offline sessions read them from the download's
    /// snapshot.
    ///
    /// Empty means no chapter UI at all, including Jellyfin's
    /// single-dummy-chapter case — a rule that lives in `MediaItem.chapters`.
    private(set) var chapters: [Chapter] = []

    /// The chapter the playhead is inside: the last starting at or before
    /// `currentTime`, `nil` with no chapters. Computed rather than cached, unlike
    /// `endCreditsSegment`: it is read only from view code already re-rendering
    /// on `currentTime`, and a `last(where:)` over a short list costs less than
    /// keeping a second value in sync.
    var currentChapter: Chapter? {
        chapters.chapter(at: currentTime)
    }

    let engine: PlaybackEngine
    let itemID: String
    let startFromBeginning: Bool
    /// A Playlist's ordered, audio-filtered members; empty for every ordinary
    /// presentation. When non-empty it wins outright over the per-series lookup
    /// in `loadNextUpItem(for:images:)`: Jellyfin has no server-side "continue
    /// this playlist", and the whole list is already in memory.
    let playbackQueue: [MediaItem]
    /// The version the caller requested: the version prompt's answer, or a
    /// remembered preference for a Resume. `nil` lets `start()` fall back to the
    /// server's default.
    let requestedMediaSourceID: String?

    /// The version `start()` actually played, resolved from `playbackInfo`:
    /// `requestedMediaSourceID` when it matched a source, else the server's
    /// default. Reported with every progress and stop call so the session
    /// reflects the real file rather than what was asked for.
    private(set) var activeMediaSourceID: String?

    /// The negotiated `PlaybackInfoResponse.playSessionId`, meaningful only in
    /// "Allow Transcoding" mode where the server allocates a session; `nil` in
    /// Direct Play Always. Reported with every start, progress and stop call so
    /// the server can track and kill the right transcode job.
    private(set) var activePlaySessionID: String?

    /// The resolved source's video stream — Jellyfin's server-side probe result,
    /// `videoRangeType` in particular — which `PlaybackStatsOverlay` shows
    /// alongside AetherEngine's own `sourceColorFormat`. Set once in `start()`.
    private(set) var sourceVideoStream: MediaStream?
    /// The resolved source's default audio stream, for the same reason
    /// `sourceVideoStream` exists: on the `nativeRemoteHLS` bypass route
    /// AetherEngine probes neither audio nor video, so
    /// `PlaybackStatsOverlay`'s "Source Channels" row would stay blank.
    ///
    /// Falls back to the first stream when none is marked default — rare, and
    /// this is a diagnostics display rather than the actual track selection.
    private(set) var sourceAudioStream: MediaStream?
    /// The server's version string, fetched lazily by `refreshServerVersion()`
    /// rather than in `start()`: diagnostics-only, and not worth a round trip at
    /// playback startup.
    private(set) var serverVersion: String?
    /// The live session the server tracks for this device, refreshed by
    /// `PlaybackStatsOverlay` while visible. `nil` until the first fetch.
    private(set) var streamingSession: SessionInfoDto?

    private let client: JellyfinAPIClient
    private let userID: String
    private let trackPreferenceStore: TrackPreferenceStore
    private let nextUpPreferenceStore: NextUpPreferenceStore
    private let streamPreferenceStore: StreamPreferenceStore
    /// Set via `init`'s `downloadedItem:`. When non-nil, `start()`, `stop()` and
    /// progress reporting route through the local-only offline paths rather than
    /// the network. `itemID` should still be `downloadedItem.itemID` — the same
    /// Jellyfin item, played from a local file — and `client`/`userID` remain
    /// valid to pass through, so callers need no offline-only initializer.
    private let downloadedItem: DownloadedItem?
    private let downloadStore: DownloadStore?
    /// `true` for a session playing an offline download.
    /// `PlaybackStatsOverlay`'s Streaming section reads it to show "Download" as
    /// the play method and skip the network-only rows.
    var isOfflinePlayback: Bool { downloadedItem != nil }
    private var progressReportTask: Task<Void, Never>?
    /// Resolved in `start()`/`startOffline()` once `activeMediaSourceID` is known.
    /// Existential rather than concrete, since `startOffline()` installs
    /// `OfflineTrickplayThumbnailProvider` and everything downstream needs only
    /// `thumbnail(atSeconds:)`.
    private var trickplayProvider: (any ScrubThumbnailProviding)?

    var audioTracks: [PlaybackTrack] { engine.audioTracks }
    var subtitleTracks: [PlaybackTrack] { engine.subtitleTracks }
    var videoFormatDescription: String? { engine.videoFormatDescription }
    var videoNaturalSize: CGSize? { engine.videoNaturalSize }
    /// A fresh snapshot per access, uncached: `PlaybackStatsOverlay` polls it on
    /// its own timer only while visible, so there is nothing to keep in sync.
    var stats: PlaybackStats { engine.stats }

    /// The total `NextUpOverlay`'s ring computes a remaining fraction against,
    /// since an elapsing count has no notion of its starting point.
    ///
    /// Whichever total governs the countdown in effect:
    /// `endCreditsCountdownTotalSeconds` once this item has an end-credits
    /// segment, else the configured preference. Before
    /// `nextUpCountdownAnchorTime` has a value, falls back to the flat
    /// `endCreditsCountdownSeconds` cap — nothing shows the ring then anyway,
    /// `nextUpSecondsRemaining` being `nil` until there is an anchor.
    var nextUpTotalCountdownSeconds: Int? {
        guard endCreditsSegment != nil else { return nextUpPreferenceStore.countdownSeconds }
        guard let total = endCreditsCountdownTotalSeconds else { return Self.endCreditsCountdownSeconds }
        return Int(total.rounded())
    }

    /// Cap on the end-credits countdown, which replaces the configured
    /// preference entirely once such a segment exists (see
    /// `nextUpSecondsRemaining`).
    private static let endCreditsCountdownSeconds = 10

    /// The last `.outro` segment chronologically. Jellyfin has no separate
    /// opening- versus closing-credits type, so an item with a mid-content
    /// credits roll and true end credits reports two; only the later one counts
    /// as the end credits. `nil` for most content, and before `mediaSegments`
    /// resolves.
    ///
    /// Cached by `loadMediaSegments(for:)` rather than recomputed per read:
    /// `updateNextUpCountdownAnchor()` reads it on every engine tick, ~10x a
    /// second for the whole session, plus once or twice more per render.
    /// `mediaSegments` is set once and never mutated, so there is exactly one
    /// moment this can change and no staleness risk.
    private var endCreditsSegment: PlaybackSegment?

    /// The playhead the end-credits countdown is timed from, distinct from
    /// `endCreditsSegment.startSeconds`: scrubbing past where a
    /// from-the-segment's-start countdown would have finished computed an
    /// already-negative `remaining` on landing, silently auto-advancing with no
    /// countdown UI shown.
    ///
    /// `updateNextUpCountdownAnchor()` sets this the moment `currentTime`
    /// re-enters the segment, from playback or a seek landing inside it, and
    /// `seek(to:)` clears it first, so any explicit jump re-anchors where it
    /// lands rather than reusing a stale anchor. `nil` outside the segment.
    private var nextUpCountdownAnchorTime: TimeInterval?

    /// `endCreditsCountdownSeconds`, capped to the duration remaining from the
    /// anchor, so a segment or scrub landing inside the final ten seconds reaches
    /// `0` at the asset's true end rather than implying a target past it. `nil`
    /// before there is an anchor.
    private var endCreditsCountdownTotalSeconds: Double? {
        guard let anchor = nextUpCountdownAnchorTime else { return nil }
        return max(0, min(Double(Self.endCreditsCountdownSeconds), duration - anchor))
    }

    /// Called from `onTimeUpdate` on every engine tick. A rising-edge detector:
    /// once set, the anchor is left alone as `currentTime` moves forward through
    /// the segment, letting a countdown complete, and re-derived only when
    /// `currentTime` re-enters from outside — which `seek(to:)` arranges after
    /// any explicit jump by clearing the anchor first.
    private func updateNextUpCountdownAnchor() {
        guard let endCreditsSegment, currentTime >= endCreditsSegment.startSeconds else {
            nextUpCountdownAnchorTime = nil
            return
        }
        if nextUpCountdownAnchorTime == nil {
            nextUpCountdownAnchorTime = currentTime
        }
    }

    /// Seconds remaining while the Up Next prompt should show; `nil` otherwise —
    /// no next episode, the feature off, dismissed this session, or outside the
    /// countdown window. Derived from `duration` and `currentTime` with no
    /// `Timer` of its own: `currentTime` already ticks ~10x a second and holds
    /// steady while paused, so this updates and freezes for free.
    ///
    /// Clamped to `0` rather than excluded once `remaining` reaches it.
    /// `currentTime` doesn't reliably stop at `duration` — the transport clock
    /// keeps advancing past the item's real end — so an earlier `remaining > 0`
    /// guard let this jump from `1` straight to `nil`, skipping the exact `0`
    /// that `PlayerView`'s auto-advance trigger fires on. Reaching
    /// `advanceToNextEpisode()` is itself what clears the prompt now.
    ///
    /// Suppressed while `isPictureInPictureActive`: auto-advancing in PiP tears
    /// down the engine and the `AVPictureInPictureController` it owns, closing
    /// the PiP window with no guarantee it returns — auto-PiP only re-triggers on
    /// a fresh foreground-to-background transition, so a next episode mounting
    /// while backgrounded plays invisibly. `PictureInPictureOverlay` already
    /// covers `NextUpOverlay` then, so this only makes the state match the
    /// screen; it recomputes the moment PiP ends.
    ///
    /// **End-credits override:** an `endCreditsSegment`'s start time replaces the
    /// duration-relative trigger entirely, leaving the `countdownSeconds`
    /// preference to govern only whether Up Next is enabled. The card appears as
    /// the segment starts and counts down `endCreditsCountdownTotalSeconds`,
    /// however that compares to the preference window — a later segment stays
    /// hidden until it starts, and an earlier one fires then. This is the
    /// intended behaviour in both directions, not whichever fires first.
    ///
    /// Timed from `nextUpCountdownAnchorTime` rather than the segment's start,
    /// for the scrub-landing bug that property documents.
    ///
    /// Truncates rather than rounds up, matching
    /// `PlayerControlsOverlay.formatTime`: a fractional `remaining` rarely lands
    /// on a whole second, so rounding up read one higher than the scrubber's own
    /// remaining-time label.
    var nextUpSecondsRemaining: Int? {
        guard nextEpisode != nil, !isNextUpDismissed, !isPictureInPictureActive,
              let countdownSeconds = nextUpPreferenceStore.countdownSeconds,
              duration > 0 else { return nil }

        if endCreditsSegment != nil {
            guard let anchor = nextUpCountdownAnchorTime, let total = endCreditsCountdownTotalSeconds else { return nil }
            let remaining = total - (currentTime - anchor)
            return max(0, Int(remaining))
        }

        let remaining = duration - currentTime
        guard remaining <= Double(countdownSeconds) else { return nil }
        return max(0, Int(remaining))
    }

    /// Segment ids `skipSegment(_:)` or `dismissSkipSegment(_:)` has already
    /// been called for — see those methods' doc comments. Sticks for the
    /// rest of this item's playback, same "once acted on, don't resurrect
    /// it" treatment `isNextUpDismissed` gives the Up Next card's Cancel
    /// button. Shared by both actions rather than a second set, since
    /// either one means the same thing to `currentSkipSegment`: don't show
    /// this segment's button again.
    private var skippedSegmentIDs: Set<String> = []

    /// The segment (any kind) containing `currentTime` right now, if any —
    /// drives `SkipSegmentOverlay`'s plain "Skip Intro"/"Skip Recap"/etc.
    /// button. Suppressed for the item's end-credits segment specifically
    /// whenever `nextUpSecondsRemaining` is covering that window instead
    /// (`PlayerView` mounts both overlays in the same bottom-trailing slot,
    /// and only one should ever be showing there); suppressed entirely
    /// during PiP — same reasoning as `nextUpSecondsRemaining`'s own guard,
    /// nothing should be interactive over `PictureInPictureOverlay`'s
    /// placeholder; and suppressed for any segment already in
    /// `skippedSegmentIDs` — the button needs to disappear the instant it's
    /// tapped, not once `currentTime` actually catches up to the seek
    /// target, which can lag behind by a buffering spell's worth of time.
    var currentSkipSegment: PlaybackSegment? {
        guard !isPictureInPictureActive,
              let segment = mediaSegments.first(where: { $0.startSeconds <= currentTime && currentTime < $0.endSeconds }),
              !skippedSegmentIDs.contains(segment.id)
        else { return nil }
        if segment.id == endCreditsSegment?.id, nextUpSecondsRemaining != nil {
            return nil
        }
        return segment
    }

    init(
        client: JellyfinAPIClient, userID: String, itemID: String, engine: PlaybackEngine,
        startFromBeginning: Bool = false, mediaSourceID: String? = nil,
        trackPreferenceStore: TrackPreferenceStore = TrackPreferenceStore(),
        nextUpPreferenceStore: NextUpPreferenceStore = NextUpPreferenceStore(),
        streamPreferenceStore: StreamPreferenceStore = StreamPreferenceStore(),
        // Non-nil routes this session through the offline playback path.
        downloadedItem: DownloadedItem? = nil,
        downloadStore: DownloadStore? = nil,
        playbackQueue: [MediaItem] = []
    ) {
        self.client = client
        self.userID = userID
        self.itemID = itemID
        self.engine = engine
        self.startFromBeginning = startFromBeginning
        self.requestedMediaSourceID = mediaSourceID
        self.trackPreferenceStore = trackPreferenceStore
        self.nextUpPreferenceStore = nextUpPreferenceStore
        self.streamPreferenceStore = streamPreferenceStore
        self.downloadedItem = downloadedItem
        self.downloadStore = downloadStore
        self.playbackQueue = playbackQueue

        engine.onStateChange = { [weak self] state in
            guard let self else { return }
            self.state = state
            // `PlayerView`'s error overlay reads `errorMessage`, so a terminal
            // engine failure must set it here as well as in `start()`'s catch.
            // Otherwise the video freezes on its last frame with no spinner and
            // no message, `.failed` being visible only in the stats overlay.
            if case .failed(let failure) = state {
                self.progressReportTask?.cancel()
                self.errorMessage = failure.message
                self.failureCategory = failure.category
            }
        }
        engine.onTimeUpdate = { [weak self] time, duration in
            self?.currentTime = time
            self?.duration = duration
            self?.updateNextUpCountdownAnchor()
        }
        engine.onSubtitleCuesChange = { [weak self] cues in self?.subtitleCues = cues }
        engine.onSourceTimeUpdate = { [weak self] sourceTime in self?.sourceTime = sourceTime }
        engine.onPictureInPicturePossibleChange = { [weak self] possible in self?.isPictureInPicturePossible = possible }
        engine.onPictureInPictureActiveChange = { [weak self] active in self?.isPictureInPictureActive = active }
    }

    /// - Parameter resumeSeconds: Seeks here after loading instead of consulting
    ///   the server's possibly-stale `resumePositionSeconds`. Used to resume in
    ///   place after a connectivity-loss retry, where the caller knows exactly
    ///   where playback stopped.
    func start(resumeSeconds: TimeInterval? = nil) async {
        errorMessage = nil
        failureCategory = nil
        if let downloadedItem {
            await startOffline(downloadedItem, resumeSeconds: resumeSeconds)
            return
        }
        do {
            let images = await client.makeImageURLBuilder()
            // The one caller of `item(userID:itemID:)` needing `Trickplay`, for
            // `trickplayProvider` below.
            let dto = try await client.item(userID: userID, itemID: itemID, fields: JellyfinAPIClient.detailFieldsWithTrickplay)
            // AUDIO SUPPRESSION: `/Items/{itemId}` has no server-side type
            // filter, so stop here before handing an audio stream to an engine
            // built for video, should a request bypass the detail screen. Route
            // to an audio-capable engine once one exists.
            guard !dto.isAudioContent else {
                errorMessage = String(localized: "Audio and music playback aren't supported.")
                return
            }
            let mediaItem = MediaItem(dto: dto, images: images)
            item = mediaItem
            // Straight off the DTO just fetched; no separate request.
            chapters = mediaItem.chapters
            // Title and subtitle land immediately so the lock screen has
            // something; artwork trails in via `loadNowPlayingArtwork(for:)`
            // rather than blocking this.
            engine.setNowPlayingInfo(title: mediaItem.railTitle, subtitle: mediaItem.railSubtitle, artwork: nil)
            loadNowPlayingArtwork(for: mediaItem)
            loadNextUpItem(for: mediaItem, images: images)
            loadMediaSegments(for: mediaItem)

            // A `DeviceProfile` is built only in "Allow Transcoding" mode; `nil`
            // leaves Direct Play Always sending a non-negotiated request.
            let deviceProfile: DeviceProfile?
            let maxStreamingBitrate: Int?
            if streamPreferenceStore.decisionMode == .allowTranscoding {
                maxStreamingBitrate = streamPreferenceStore.streamingMaxBitrate.bitsPerSecond
                deviceProfile = DeviceProfileBuilder.build(maxStreamingBitrate: maxStreamingBitrate)
            } else {
                deviceProfile = nil
                maxStreamingBitrate = nil
            }
            let playbackInfo = try await client.playbackInfo(
                itemID: itemID, userID: userID, mediaSourceID: requestedMediaSourceID,
                deviceProfile: deviceProfile, maxStreamingBitrate: maxStreamingBitrate
            )
            // The requested id may match nothing — a stale preference for a
            // removed version — so fall back to the server's default.
            let source = requestedMediaSourceID.flatMap { id in playbackInfo.mediaSources?.first { $0.id == id } }
                ?? playbackInfo.mediaSources?.first
            activeMediaSourceID = source?.id
            activePlaySessionID = playbackInfo.playSessionId
            sourceVideoStream = source?.mediaStreams?.first { $0.type == "Video" }
            let audioStreams = source?.mediaStreams?.filter { $0.type == "Audio" } ?? []
            sourceAudioStream = audioStreams.first { $0.isDefault == true } ?? audioStreams.first
            if let mediaSourceID = activeMediaSourceID,
               let info = TrickplayMath.bestInfo(from: mediaItem.dto.trickplay, mediaSourceID: mediaSourceID) {
                trickplayProvider = TrickplayThumbnailProvider(itemID: itemID, info: info, imageURLBuilder: images)
            }

            // `transcodingUrl`'s presence is the server's direct-play-versus-
            // transcode verdict, and it is populated only in "Allow Transcoding"
            // mode. Absent — always, in Direct Play Always — this falls back to
            // the `streamURL` builder.
            let url: URL
            let isRemoteHLS: Bool
            if let transcodingPath = source?.transcodingUrl,
               let transcodingURL = await client.resolveTranscodingURL(transcodingPath) {
                url = transcodingURL
                isRemoteHLS = true
            } else {
                guard let directURL = await client.streamURL(itemID: itemID, mediaSourceID: source?.id, container: source?.container) else {
                    errorMessage = String(localized: "Couldn't build a playback URL for this item.")
                    return
                }
                url = directURL
                isRemoteHLS = false
            }

            var externalSubtitles: [ExternalSubtitleSource] = []
            if let source, let mediaSourceID = source.id {
                externalSubtitles = await Self.externalSubtitleSources(
                    itemID: itemID, mediaSourceID: mediaSourceID, mediaStreams: source.mediaStreams ?? [], client: client
                )
            }
            let atmosAudioTrackIndices = Self.atmosAudioTrackIndices(from: source?.mediaStreams ?? [])

            try await engine.load(
                url: url, externalSubtitles: externalSubtitles, knownAtmosAudioTrackIndices: atmosAudioTrackIndices, isRemoteHLS: isRemoteHLS
            )
            applyStoredTrackSelection()
            // An explicit `resumeSeconds` wins over the server's last-known
            // position and ignores `startFromBeginning`: this recovers an
            // already-started session rather than honouring a play-from-the-top
            // request.
            if let resumeSeconds, resumeSeconds > 0 {
                await engine.seek(to: resumeSeconds)
            } else if !startFromBeginning, let resumeSeconds = mediaItem.resumePositionSeconds, resumeSeconds > 0 {
                await engine.seek(to: resumeSeconds)
            }
            engine.play()

            try? await client.reportPlaybackStart(itemID: itemID, mediaSourceID: activeMediaSourceID, playSessionID: activePlaySessionID)
            startProgressReporting()
        } catch is CancellationError {
            // A superseded load — rapid next-episode navigation, or backing out
            // mid-load — not a playback failure.
        } catch let loadFailure as PlaybackLoadFailure {
            // `state` must reach `.failed` here, not just `errorMessage`:
            // `AetherPlaybackEngine.load(...)` suppresses the matching `.error`
            // phase it would otherwise bridge through `onStateChange`, the only
            // other place `state` becomes `.failed`. Without this it stays stuck
            // wherever the load left it, rendering
            // `PlayerControlsOverlay`'s buffering spinner over the error overlay.
            state = .failed(loadFailure.failure)
            errorMessage = loadFailure.failure.message
            failureCategory = loadFailure.failure.category
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? String(localized: "Playback failed to start.")
            failureCategory = .transient
        }
    }

    /// `start()`'s offline counterpart. Builds a `file://` URL and local
    /// `ExternalSubtitleSource`s from `DownloadFileStore`, and skips every
    /// network call `start()` makes — item fetch, `playbackInfo`,
    /// `reportPlaybackStart`, next-episode lookup — in favour of the download's
    /// stored snapshot. `nextEpisode` simply stays `nil`. Progress and stop route
    /// to `writeOfflineProgress(_:)`.
    ///
    /// `item` is still populated, with a synthetic `MediaItem` built from an
    /// otherwise-empty `BaseItemDto` carrying the stored title and episode info,
    /// so `PlayerControlsOverlay`'s title row works unmodified. With no
    /// `imageTags` its image URLs all resolve to `nil`, which is why the logo
    /// comes from `offlineLogoURL` — a downloaded local file. Without that,
    /// `titleRow` fell back to title text for every download, including ones with
    /// a cached logo on disk.
    private func startOffline(_ downloadedItem: DownloadedItem, resumeSeconds: TimeInterval?) async {
        let dto = BaseItemDto(
            id: downloadedItem.itemID,
            name: downloadedItem.title,
            type: downloadedItem.kind == .episode ? .episode : .movie,
            runTimeTicks: downloadedItem.runtimeTicks,
            seriesId: downloadedItem.seriesID,
            seriesName: downloadedItem.seriesTitle,
            indexNumber: downloadedItem.episodeNumber,
            parentIndexNumber: downloadedItem.seasonNumber
        )
        // Any placeholder base URL works: with no `imageTags` on `dto`, nothing
        // this builder can build is ever requested.
        let mediaItem = MediaItem(dto: dto, images: ImageURLBuilder(baseURL: URL(string: "https://offline.invalid")!))
        item = mediaItem
        // The same `logoImagePath` to file-URL resolution
        // `DownloadedAssetDetailView` uses; `nil` when this download has no logo.
        offlineLogoURL = downloadedItem.logoImagePath.map(DownloadFileStore.url(forRelativePath:))
        engine.setNowPlayingInfo(title: mediaItem.railTitle, subtitle: mediaItem.railSubtitle, artwork: nil)

        activeMediaSourceID = downloadedItem.mediaSourceID
        mediaSegments = downloadedItem.segments.map(PlaybackSegment.init(downloaded:))
        endCreditsSegment = mediaSegments.filter { $0.kind == .outro }.max { $0.startSeconds < $1.startSeconds }
        // Empty for a download predating chapter support, or an item with no
        // chapters — the same no-chapter-UI outcome either way.
        chapters = downloadedItem.chapters.map(Chapter.init(downloaded:))
        // `nil`, so no scrub thumbnails, when this download predates trickplay
        // support or its best-effort fetch came up empty.
        if let trickplayInfo = downloadedItem.trickplayInfo {
            trickplayProvider = OfflineTrickplayThumbnailProvider(itemID: downloadedItem.itemID, info: trickplayInfo)
        }

        let videoURL = DownloadFileStore.url(forRelativePath: downloadedItem.videoFilePath)
        let externalSubtitles = downloadedItem.subtitleFiles.map { file in
            ExternalSubtitleSource(
                url: DownloadFileStore.url(forRelativePath: file.relativePath),
                name: file.displayTitle,
                language: file.language,
                isForced: file.isForced,
                isHearingImpaired: file.isHearingImpaired,
                isDefault: file.isDefault
            )
        }

        do {
            try await engine.load(url: videoURL, externalSubtitles: externalSubtitles, knownAtmosAudioTrackIndices: [])
            applyStoredTrackSelection()
            if let resumeSeconds, resumeSeconds > 0 {
                await engine.seek(to: resumeSeconds)
            } else if !startFromBeginning, downloadedItem.resumePositionTicks > 0 {
                await engine.seek(to: Double(downloadedItem.resumePositionTicks) / 10_000_000)
            }
            engine.play()
            startOfflineProgressReporting(downloadedItem)
        } catch is CancellationError {
            // A superseded load, not a playback failure; see `start()`.
        } catch let loadFailure as PlaybackLoadFailure {
            // `state` must reach `.failed` here too; see `start()`'s catch.
            state = .failed(loadFailure.failure)
            errorMessage = loadFailure.failure.message
            failureCategory = loadFailure.failure.category
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? String(localized: "Playback failed to start.")
            failureCategory = .transient
        }
    }

    /// Fraction played at which offline playback counts an item watched. There is
    /// no server to defer that judgement to, so this stands in at Jellyfin's own
    /// common default threshold.
    private static let offlineWatchedThreshold = 0.9

    private func startOfflineProgressReporting(_ downloadedItem: DownloadedItem) {
        progressReportTask?.cancel()
        progressReportTask = Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let self else { return }
                self.writeOfflineProgress(downloadedItem)
            }
        }
    }

    /// Writes resume and watched state onto the `DownloadedItem` row and marks it
    /// `pendingSync`: the offline counterpart to the `reportPlayback*` calls,
    /// which this path must never need. `DownloadSyncManager` pushes it to the
    /// server once reconnected.
    ///
    /// `currentTime`/`duration` default to this view model's live properties,
    /// which is what the periodic call site wants. `stop()` passes pre-captured
    /// values instead, for the reason its own comment gives.
    private func writeOfflineProgress(_ downloadedItem: DownloadedItem, currentTime: TimeInterval? = nil, duration: TimeInterval? = nil) {
        let currentTime = currentTime ?? self.currentTime
        let duration = duration ?? self.duration
        guard duration > 0 else { return }
        let fraction = min(1, max(0, currentTime / duration))
        if fraction >= Self.offlineWatchedThreshold {
            downloadedItem.isPlayed = true
            downloadedItem.resumePositionTicks = 0
            downloadedItem.playedPercentage = 100
        } else {
            downloadedItem.resumePositionTicks = Int64(currentTime * 10_000_000)
            downloadedItem.playedPercentage = fraction * 100
        }
        // Captured here, while it is happening and possibly fully offline, rather
        // than left for the server to infer when `DownloadSyncManager` reaches it
        // days later.
        downloadedItem.lastPlayedAt = Date()
        downloadedItem.pendingSync = true
        downloadStore?.save()
    }

    /// Fire-and-forget: fetches the poster and re-stages Now Playing with it.
    /// Title and subtitle already went in synchronously in `start()`, so this only
    /// adds artwork. A failed fetch leaves Now Playing without it, and nothing
    /// here can fail `start()`.
    private func loadNowPlayingArtwork(for item: MediaItem) {
        guard let artworkURL = item.primaryImageURL else { return }
        Task { [weak self] in
            guard let image = try? await RemoteImageLoader.shared.image(for: artworkURL) else { return }
            self?.engine.setNowPlayingInfo(title: item.railTitle, subtitle: item.railSubtitle, artwork: image)
        }
    }

    /// Resolves `nextEpisode` for the Up Next prompt, in the two modes that
    /// property documents.
    ///
    /// Queue mode resolves synchronously — the ordered array is already in memory
    /// — with no failure beyond not-found, leaving `nextEpisode` as it was, or
    /// already-last, leaving it `nil`. It wins outright over episode mode, even
    /// for an episode reached via a playlist: the playlist's explicit order is the
    /// point, and it shouldn't fall back to that episode's series position.
    ///
    /// Episode mode is fire-and-forget via `JellyfinAPIClient.nextEpisode(...)`,
    /// which can answer this where `nextUp(...)` can't. A no-op for non-episode
    /// content or an episode DTO missing `seriesId`/`seasonId`; a failed fetch
    /// leaves `nextEpisode` `nil`.
    private func loadNextUpItem(for item: MediaItem, images: ImageURLBuilder) {
        if !playbackQueue.isEmpty {
            guard let index = playbackQueue.firstIndex(where: { $0.id == item.id }),
                  index + 1 < playbackQueue.count else { return }
            nextEpisode = playbackQueue[index + 1]
            return
        }

        guard item.kind == .episode, let seriesID = item.dto.seriesId, let seasonID = item.dto.seasonId else { return }
        let userID = self.userID
        Task { [weak self] in
            guard let dto = try? await self?.client.nextEpisode(
                currentEpisodeID: item.id, seriesID: seriesID, seasonID: seasonID, userID: userID
            ) else { return }
            self?.nextEpisode = MediaItem(dto: dto, images: images)
        }
    }

    /// The Up Next prompt's Cancel button; `isNextUpDismissed` covers why this
    /// sticks for the rest of the item rather than hiding the card once.
    func dismissNextUp() {
        isNextUpDismissed = true
    }

    /// Fire-and-forget, like `loadNextUpItem(for:images:)`'s episode mode, but
    /// not episode-only: movies get Skip Intro too. A failed fetch, including an
    /// older server without the Media Segments feature, leaves `mediaSegments`
    /// empty — a bonus rather than a requirement, like external subtitles.
    ///
    /// Also derives `endCreditsSegment` here, which that property explains.
    private func loadMediaSegments(for item: MediaItem) {
        Task { [weak self] in
            guard let dtos = try? await self?.client.mediaSegments(itemID: item.id) else { return }
            let segments = dtos.compactMap(PlaybackSegment.init(dto:))
            self?.mediaSegments = segments
            self?.endCreditsSegment = segments.filter { $0.kind == .outro }.max { $0.startSeconds < $1.startSeconds }
        }
    }

    /// `SkipSegmentOverlay`'s button: records the segment as skipped, which hides
    /// the button at once through `currentSkipSegment` rather than waiting for
    /// the seek to land, then jumps to the segment's end via `seek(to:)`.
    func skipSegment(_ segment: PlaybackSegment) {
        skippedSegmentIDs.insert(segment.id)
        seek(to: segment.endSeconds)
    }

    /// `SkipSegmentOverlay`'s swipe-to-dismiss and its VoiceOver close button.
    /// Records the segment as `skipSegment(_:)` does, so the button stays gone
    /// for this segment's window, but does not seek: dismissing means stop
    /// offering to skip, not skip anyway.
    func dismissSkipSegment(_ segment: PlaybackSegment) {
        skippedSegmentIDs.insert(segment.id)
    }

    /// Maps a resolved source's external subtitle streams into
    /// `ExternalSubtitleSource`s for the load. `JellyfinAPIClient.subtitleURL`
    /// covers why the URL is built from ids rather than read off the stream. An
    /// unresolvable URL is skipped rather than failing the load; external
    /// subtitles are a bonus, not a requirement.
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

    /// Audio track indices Jellyfin's probe flagged as Dolby Atmos, forwarded as
    /// `knownAtmosAudioTrackIndices` so the picker can flag a track AetherEngine
    /// can't detect itself — TrueHD's Atmos extension. Reads
    /// `audioSpatialFormat` rather than text-matching the codec or title, which
    /// that field documents as less reliable.
    ///
    /// Returns physical indices matching `PlaybackTrack.id`, not
    /// `MediaStream.index` verbatim: Jellyfin numbers external streams into the
    /// same sequence as embedded ones, though they carry no bytes in the
    /// container AetherEngine demuxes, so a source with one external subtitle at
    /// index 0 reports every embedded audio stream one higher than AetherEngine
    /// numbers it. Subtracting the count of preceding external streams recovers
    /// the physical index.
    static func atmosAudioTrackIndices(from mediaStreams: [MediaStream]) -> Set<Int> {
        let externalIndices = mediaStreams.filter { $0.isExternal == true }.map(\.index)
        func physicalIndex(_ index: Int) -> Int {
            index - externalIndices.filter { $0 < index }.count
        }
        return Set(mediaStreams
            .filter { $0.type == "Audio" && $0.audioSpatialFormat == "DolbyAtmos" }
            .map { physicalIndex($0.index) })
    }

    /// Restores the tracks last explicitly picked for this item, overriding what
    /// `engine.load(...)` defaulted to — including
    /// `AetherPlaybackEngine`'s forced-subtitle auto-select, documented as a
    /// one-time default an explicit selection overrides. Does nothing with no
    /// stored preference, leaving that default in place.
    ///
    /// A stored track is restored only when one with the same id and title still
    /// exists: ids are physical container positions, so the same id can point at
    /// a different track after a layout change. A mismatch is skipped rather than
    /// passed through.
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

    /// Clears `nextUpCountdownAnchorTime` before seeking. This is the one choke
    /// point every explicit jump goes through — scrubber, skip buttons,
    /// VoiceOver's adjustable action — and each must re-anchor the end-credits
    /// countdown where it lands rather than reuse a stale one.
    func seek(to time: TimeInterval) {
        nextUpCountdownAnchorTime = nil
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

    /// `true` once `start()` has resolved a trickplay track for the active source.
    /// `PlayerControlsOverlay` gates the scrub-preview bubble on this, the same
    /// self-disabling treatment the PiP button gets. `false` for unscanned
    /// content, and before `start()` resolves.
    var supportsScrubThumbnails: Bool { trickplayProvider != nil }

    /// Passthrough to `trickplayProvider.thumbnail(atSeconds:)`. A `nil` means
    /// keep showing the last still, and is rare here: a miss needs a request or
    /// decode failure, not the not-yet-resident case AetherEngine's cache had.
    func scrubThumbnail(atSeconds seconds: Double) async -> CGImage? {
        await trickplayProvider?.thumbnail(atSeconds: seconds)
    }

    /// Fetches `serverVersion` once and caches it, short-circuiting on later
    /// calls, so `PlaybackStatsOverlay` can call it on every poll tick.
    func refreshServerVersion() async {
        // Offline playback has no server to ask, so this never dispatches a
        // doomed request.
        guard !isOfflinePlayback, serverVersion == nil else { return }
        serverVersion = try? await client.publicSystemInfo().version
    }

    /// Refreshes `streamingSession` from the server's live view of this device's
    /// session. Leaves the last known value on screen on failure rather than
    /// blanking the Streaming section over one dropped request. A no-op offline,
    /// where there is no live session to report on.
    func refreshStreamingSession() async {
        guard !isOfflinePlayback else { return }
        if let session = try? await client.currentSession(deviceID: DeviceIdentity.deviceID) {
            streamingSession = session
        }
    }

    func stop() async {
        progressReportTask?.cancel()
        if let downloadedItem {
            // Captured before `engine.stop()`, which synchronously zeroes
            // AetherEngine's clock and duration. Those reach
            // `self.currentTime`/`.duration` through `observeEngine()`'s sinks,
            // which defer to the next run-loop turn, so reading them afterwards
            // sees pre-stop values only by that scheduling detail.
            let capturedTime = currentTime
            let capturedDuration = duration
            engine.stop()
            writeOfflineProgress(downloadedItem, currentTime: capturedTime, duration: capturedDuration)
            return
        }
        let ticks = Int64(currentTime * 10_000_000)
        engine.stop()
        // Skipped while known-offline rather than awaited: a guaranteed failure
        // still costs `sendRaw`'s 20s timeout, stalling every caller of `stop()`
        // including `PlayerView.tearDown()`, so any close affordance sat doing
        // nothing for up to 20 seconds before dismissing.
        //
        // Keyed on live connectivity rather than `isOfflinePlayback`: a download
        // takes the branch above, and this one only runs for a live session whose
        // server became unreachable mid-session.
        if !ConnectivityMonitor.shared.isOffline {
            try? await client.reportPlaybackStopped(itemID: itemID, positionTicks: ticks, mediaSourceID: activeMediaSourceID, playSessionID: activePlaySessionID)
        }
    }

    private func startProgressReporting() {
        progressReportTask?.cancel()
        progressReportTask = Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let self else { return }
                let ticks = Int64(self.currentTime * 10_000_000)
                let isPaused = self.state == .paused
                // Best-effort and silent: a real connectivity loss surfaces
                // through `ConnectivityMonitor` on the next load, and one missed
                // heartbeat self-heals — the next tick retries and `stop()` still
                // attempts a final save. Logged for a diagnostic trail.
                do {
                    try await self.client.reportPlaybackProgress(
                        itemID: self.itemID, positionTicks: ticks, isPaused: isPaused,
                        mediaSourceID: self.activeMediaSourceID, playSessionID: self.activePlaySessionID
                    )
                } catch {
                    Self.logger.debug("reportPlaybackProgress failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}
