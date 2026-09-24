import CoreGraphics
import Foundation
import OSLog
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
    /// Renders authored ASS/SSA styling. Owns its own frame state;
    /// `SubtitleOverlayView` paints what it produces and suppresses its own text
    /// rendering while `isRenderingStyledASS`.
    let assRenderSession = ASSSubtitleRenderSession()
    /// True while the selected subtitle track is ASS/SSA and libass owns the
    /// paint for it.
    private(set) var isRenderingStyledASS = false
    /// Bumped whenever libass produces a new frame, so the overlay's body
    /// re-runs (the session itself is deliberately not `@Observable`).
    private(set) var assFrameGeneration = 0
    /// The time libass renders at, and the one its accessibility text is read
    /// at: `sourceTime`, whenever `assSeekHold` isn't holding it back.
    private(set) var assRenderTime: TimeInterval = 0
    /// True while a transcode's styled track doesn't yet know where the picture
    /// is — just after a seek, until the first line starts. The overlay paints
    /// nothing rather than a line at the wrong moment.
    private(set) var isStyledASSTimingPending = false
    /// Only on a server transcode, where the engine's playhead is briefly off
    /// the picture after every seek. See `ASSSeekHold`.
    private var assSeekHold: ASSSeekHold?
    /// Whether this session plays a server transcode through AVPlayer, the one
    /// route whose styled track needs `assSeekHold`.
    private var isRemoteHLSSession = false
    /// Guards against a slow script fetch landing after the user has moved on
    /// to a different track.
    private var assScriptTask: Task<Void, Never>?
    /// The media streams this session is playing, kept so a subtitle track
    /// selected later can be mapped back to its Jellyfin `MediaStream`.
    private var mediaStreams: [MediaStream] = []
    /// The Jellyfin streams this session handed the engine as external
    /// sidecars, in the order they were handed over — which is what makes the
    /// ordinal in `registeredSidecar(forTrack:engineTracks:registered:)`
    /// meaningful. Empty on a direct play with no sidecar files.
    private var externalSubtitleStreams: [MediaStream] = []
    /// The attachments the active source declares, kept for the same reason
    /// `mediaStreams` is: they are only needed once an authored-ASS track is
    /// selected, which can be long after `start()`.
    private var mediaAttachments: [MediaAttachment] = []
    /// Fonts fetched from the server or read off a download, for the routes
    /// where AetherEngine has none of its own. Never consulted when the engine
    /// does — see `assFonts`.
    private var fetchedASSFonts: [ASSFontAttachment] = []
    /// Coalesces the font fetch: the engine re-announces a track selection
    /// whenever it republishes the track list, and every announcement would
    /// otherwise start its own download of the same faces. Same shape as
    /// `JellyfinAPIClient`'s in-flight re-authentication task.
    private var assFontTask: Task<[ASSFontAttachment], Never>?
    /// The fetched script, held until the overlay reports its geometry.
    private var assScript: String?
    /// The track `assScript` belongs to, so a re-emitted selection for the same
    /// track doesn't re-fetch.
    private var loadedASSTrackID: Int?
    /// The track a fetch is currently in flight for. Separate from
    /// `loadedASSTrackID`, which is only set once the script has landed: the
    /// engine re-announces the selection whenever it republishes the track
    /// list, and a cold fetch can run for over a minute, so without this the
    /// announcement would cancel and restart the request every time — a cold
    /// track could never finish loading.
    private var fetchingASSTrackID: Int?
    private var assGeometry: ASSSubtitleRenderSession.Geometry?

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

    /// Whether `PlayerView` should close itself once the engine reports
    /// `.ended`, rather than leaving the last frame on screen. True whenever
    /// Up Next won't take over: nothing to play next, the countdown turned off,
    /// or the user cancelled it.
    ///
    /// Deliberately ignores `isPictureInPictureActive`, which suppresses the
    /// countdown only until PiP ends — `nextUpSecondsRemaining` recomputes to
    /// `0` then and advances, so closing here would pre-empt the next episode.
    var closesWhenPlaybackEnds: Bool {
        nextEpisode == nil || isNextUpDismissed || nextUpPreferenceStore.countdownSeconds == nil
    }

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
    /// The picture's coded size, which `SubtitleOverlayView` needs to work out
    /// where the picture actually is inside a full-bleed overlay.
    ///
    /// AetherEngine's own probe first, with Jellyfin's server-side one as the
    /// fallback — for exactly the reason `sourceVideoStream` above exists: on
    /// the `nativeRemoteHLS` bypass nothing local ever demuxes the source, so
    /// the engine reports no natural size for the whole session.
    ///
    /// `videoRect(in:)` treats a `nil` as "the picture fills the overlay",
    /// which was harmless while that route had no subtitles to place and badly
    /// wrong the moment it did: libass scaled the script to the whole screen
    /// instead of to the picture, and a transcode's dialogue came out roughly
    /// three times too large. Only the ASPECT of this is used downstream, and a
    /// Jellyfin transcode preserves it, so the source's own dimensions are the
    /// right answer even when the delivered video has been scaled down.
    var videoNaturalSize: CGSize? {
        if let size = engine.videoNaturalSize { return size }
        guard let width = sourceVideoStream?.width, let height = sourceVideoStream?.height,
              width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }
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
            guard let self else { return }
            self.currentTime = time
            self.duration = duration
            self.updateNextUpCountdownAnchor()
            // Item time on a transcode, the axis `assSeekHold` detects seeks on.
            if self.assSeekHold != nil {
                self.assSeekHold?.observeItemTime(time)
                self.applyASSRenderTime()
            }
        }
        engine.onSubtitleCuesChange = { [weak self] cues in self?.subtitleCues = cues }
        engine.onSourceTimeUpdate = { [weak self] sourceTime in
            guard let self else { return }
            self.sourceTime = sourceTime
            self.applyASSRenderTime()
        }
        engine.onNativeSubtitleCues = { [weak self] texts, itemTime in
            guard let self, self.assSeekHold != nil else { return }
            self.assSeekHold?.observeCues(texts, at: itemTime)
            self.applyASSRenderTime()
        }
        engine.onPictureInPicturePossibleChange = { [weak self] possible in self?.isPictureInPicturePossible = possible }
        engine.onPictureInPictureActiveChange = { [weak self] active in self?.isPictureInPictureActive = active }
        engine.onNativeSubtitleCaptureAttached = { [weak self] in
            self?.assSeekHold?.ignoreLinesAlreadyShowing()
        }
        engine.onSubtitleTrackChange = { [weak self] id in self?.handleSubtitleTrackChange(id) }
        // The render session is a plain object, so it pokes the view model to
        // re-run the overlay's body.
        assRenderSession.onFrameChange = { [weak self] in self?.assFrameGeneration &+= 1 }
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
            let sidecarStreams = Self.externalSubtitleStreams(
                from: source?.mediaStreams ?? [], isRemoteHLS: isRemoteHLS
            )
            if let source, let mediaSourceID = source.id {
                externalSubtitles = await Self.externalSubtitleSources(
                    itemID: itemID, mediaSourceID: mediaSourceID, streams: sidecarStreams, client: client
                )
            }
            // Kept in the order they were registered, so a track selected later
            // can be mapped back to the stream it was built from.
            self.externalSubtitleStreams = sidecarStreams
            self.mediaStreams = source?.mediaStreams ?? []
            self.mediaAttachments = source?.mediaAttachments ?? []
            // `start()` runs again on a retry and on a resume-in-place (see
            // `PlayerView`), so any cached font fetch belongs to the previous
            // attempt. Clearing it matters most for the retry: whatever made
            // playback fail plausibly failed the attachment fetch too, and
            // keeping that empty result would leave the recovered session
            // permanently unstyled.
            self.assFontTask = nil
            self.fetchedASSFonts = []
            let atmosAudioTrackIndices = Self.atmosAudioTrackIndices(from: source?.mediaStreams ?? [])

            isRemoteHLSSession = isRemoteHLS
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
            isRemoteHLSSession = false
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
    // MARK: - Authored ASS styling

    private static let assLog = Logger(subsystem: "com.dionysus.player", category: "ass-subtitles")

    /// Resolve a newly selected subtitle track to a complete ASS script, or tear
    /// the libass renderer down when the selection isn't an authored-ASS track.
    ///
    /// Only ASS/SSA goes to libass. Everything else — SubRip, WebVTT, teletext,
    /// bitmap — keeps rendering through `SubtitleOverlayView`'s own path on
    /// AetherEngine's cues, unchanged.
    private func handleSubtitleTrackChange(_ id: Int?) {
        guard let id else {
            assScriptTask?.cancel()
            fetchingASSTrackID = nil
            clearStyledASS()
            return
        }
        // Already serving, or already fetching, this track — the engine re-emits
        // the selection on its own reloads and on every track-list republish.
        guard id != loadedASSTrackID, id != fetchingASSTrackID else { return }

        // The track list is republished separately from the selected index, so a
        // selection can briefly name a track that isn't in the list yet. That is
        // not "the selection isn't ASS" — leaving the current state alone lets
        // the next emission resolve it.
        guard let track = engine.subtitleTracks.first(where: { $0.id == id }) else { return }

        Self.assLog.debug("subtitle track -> \(id) codec=\(track.codec ?? "nil") external=\(track.isExternal)")
        assScriptTask?.cancel()
        // Drop the outgoing renderer before anything else, including when the
        // new track is itself ASS. Jellyfin extracts an embedded track on
        // demand and the first request for a large file can take over a minute,
        // so without this the PREVIOUS track's styled lines would stay on
        // screen for the whole fetch — wrong subtitles, not merely unstyled
        // ones. Cleared, `SubtitleOverlayView` falls back to its own path on
        // AetherEngine's cues, which are already flowing for the newly selected
        // track, and upgrades to styled when the script lands.
        clearStyledASS()
        // The single gate for the setting. Disabled, an ASS track is treated
        // exactly like a SubRip one — `clearStyledASS()` above has already
        // handed the screen back to `SubtitleOverlayView`'s own path on
        // AetherEngine's cues, so the track still renders, just unstyled.
        guard Self.isAuthoredASS(track.codec), Self.isStyledASSEnabled() else {
            fetchingASSTrackID = nil
            return
        }
        fetchingASSTrackID = id
        assScriptTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.fetchingASSTrackID == id { self.fetchingASSTrackID = nil } }
            let started = CFAbsoluteTimeGetCurrent()
            let source = await self.assScriptSource(for: track)
            guard let source, let script = await Self.loadScript(from: source) else {
                Self.assLog.error("ass script unavailable for track \(id)")
                if !Task.isCancelled { self.clearStyledASS() }
                return
            }
            guard !Task.isCancelled,
                  self.engine.subtitleTracks.first(where: \.isSelected)?.id == id else { return }
            Self.assLog.debug("ass script loaded for track \(id): \(script.count)B, \(self.engine.fontAttachments.count) embedded fonts, fetch \(String(format: "%.1f", CFAbsoluteTimeGetCurrent() - started))s")
            self.assScript = script
            self.loadedASSTrackID = id
            self.isRenderingStyledASS = true
            self.applyPendingASSScript()
            // libass now owns the paint, so AVKit must not also draw this
            // track. It would be drawing it on a server transcode: the app's
            // sidecars are declared as real HLS renditions there, so selecting
            // one hands the drawing to AVPlayer, and the viewer got the system
            // caption and the authored one at once.
            //
            // On that route the rendition stays selected with its drawing
            // suppressed rather than deselected, because AVPlayer's timing of
            // it is what AetherEngine measures the picture against (see
            // `ASSSeekHold`).
            //
            // Deliberately only once the script has actually landed. Turning it
            // off at selection would leave a failed or still-running fetch with
            // nothing drawing at all — and on that route there is nothing to
            // fall back to, since AetherEngine publishes no cues for a track
            // AVPlayer is rendering.
            //
            // PiP is unaffected: AVKit draws the rendition itself there,
            // because the app's overlay isn't inside the captured layer, and
            // `AetherPlaybackEngine` hands it back on either route.
            if self.isRemoteHLSSession {
                self.assSeekHold = ASSSeekHold()
                self.engine.setNativeSubtitleCapture(true)
            } else {
                self.engine.setNativeSubtitleRendering(false)
            }
            self.applyASSRenderTime()

            // Fonts follow the script rather than gating it. On the common
            // (direct-play) path the engine already has them and the load
            // above already used them, so this returns without suspending and
            // nothing is loaded twice. Only a route with no local demux
            // reaches a fetch, and there a script whose faces are still
            // downloading is better rendered now in a fallback face and
            // re-rendered in its own when they land than withheld for as long
            // as the fonts take — which, for a CJK release shipping several
            // megabytes of faces over a slow link, is a long time to show
            // nothing.
            guard self.engine.fontAttachments.isEmpty else { return }
            let fonts = await self.resolveFetchedASSFonts()
            guard !fonts.isEmpty, !Task.isCancelled, self.loadedASSTrackID == id else { return }
            Self.assLog.debug("ass fonts resolved for track \(id): \(fonts.count)")
            self.fetchedASSFonts = fonts
            self.applyPendingASSScript()
        }
    }

    private func clearStyledASS() {
        assScript = nil
        loadedASSTrackID = nil
        isRenderingStyledASS = false
        assRenderSession.teardown()
        if assSeekHold != nil {
            assSeekHold = nil
            engine.setNativeSubtitleCapture(false)
        }
        applyASSRenderTime()
    }

    /// Drives libass to the current playhead, through `assSeekHold` when
    /// there is one. libass renders at a time rather than publishing a cue
    /// list, so it runs on the same clock the overlay filters cues against.
    private func applyASSRenderTime() {
        let renderTime = assSeekHold.map { $0.renderTime(for: sourceTime) } ?? sourceTime
        let isPending = renderTime == nil
        // Guarded: this runs on every clock tick, and an `@Observable` write
        // re-renders the overlay even when the value hasn't changed.
        if isStyledASSTimingPending != isPending { isStyledASSTimingPending = isPending }
        guard let renderTime else { return }
        assRenderTime = renderTime
        assRenderSession.setTime(renderTime)
    }

    /// Hands the script and the current overlay geometry to libass together.
    /// Called from both sides, because either can arrive second: the script
    /// lands from a fetch, the geometry from `SubtitleOverlayView`'s layout.
    func setASSGeometry(_ geometry: ASSSubtitleRenderSession.Geometry) {
        Self.assLog.debug("geometry frame=\(geometry.frame.debugDescription) video=\(geometry.video.debugDescription) safeArea=(t\(geometry.safeArea.top) l\(geometry.safeArea.left) b\(geometry.safeArea.bottom) r\(geometry.safeArea.right)) drawable=\(geometry.drawable.debugDescription)")
        assGeometry = geometry
        if assRenderSession.isActive {
            assRenderSession.updateGeometry(geometry)
        } else {
            applyPendingASSScript()
        }
    }

    private func applyPendingASSScript() {
        guard let assScript, let assGeometry else { return }
        assRenderSession.load(script: assScript, fonts: assFonts, geometry: assGeometry)
    }

    /// The fonts to render the current script in.
    private var assFonts: [ASSFontAttachment] {
        Self.assFonts(engineAttachments: engine.fontAttachments, fetched: fetchedASSFonts)
    }

    /// AetherEngine's own probe wins whenever it has anything, and `fetched`
    /// is the fallback for the routes where it never will.
    ///
    /// Not a merge. On a direct play the two are the same faces read out of the
    /// same container, so merging would register every one of them twice; and
    /// the engine's copy is already in memory, where the fallback costs a
    /// download or a disk read. The engine having *any* attachment is taken as
    /// it having demuxed the container — a file with fonts never probes to an
    /// empty list, so there is no case where it holds some of them and the
    /// server holds the rest.
    ///
    /// Static and pure so the rule can be asserted directly; the instance
    /// property `assFonts` is the only caller.
    static func assFonts(
        engineAttachments: [ASSFontAttachment], fetched: [ASSFontAttachment]
    ) -> [ASSFontAttachment] {
        engineAttachments.isEmpty ? fetched : engineAttachments
    }

    /// Where the selected track's script can be read from.
    ///
    /// A downloaded item already has every non-bitmap track on disk as a
    /// sidecar. Streaming, Jellyfin will extract any subtitle stream — embedded
    /// included — through `JellyfinAPIClient.subtitleURL`.
    ///
    /// Either way the selected track has to be mapped back to the right script,
    /// and neither side can be matched by id — see
    /// `downloadedSubtitleFile(forTrack:engineTracks:subtitleFiles:)` and
    /// `jellyfinStream(forTrack:engineTracks:mediaStreams:)` for why each is an
    /// ordinal instead.
    ///
    /// Non-private so tests can resolve a track without driving a real libass
    /// load: offline this is fully deterministic and touches no network, and
    /// the defect worth catching here (every track resolving to the same
    /// script) lives in this wiring rather than in either mapping.
    func assScriptSource(for track: PlaybackTrack) async -> ASSScriptSource? {
        if let downloadedItem {
            guard let file = Self.registeredSidecar(
                forTrack: track, engineTracks: engine.subtitleTracks,
                registered: downloadedItem.subtitleFiles
            ), Self.isAuthoredASSPath(file.relativePath) else { return nil }
            return .localFile(DownloadFileStore.url(forRelativePath: file.relativePath))
        }
        guard let mediaSourceID = activeMediaSourceID else { return nil }
        // Two kinds of track reach here and they map differently. A track the
        // engine demuxed out of the container is paired with its `MediaStream`
        // by ordinal among embedded ASS entries; a sidecar THIS app registered
        // is paired with the stream it was built from, by ordinal among
        // externals. Before the transcode path registered anything, an external
        // ASS track simply had no mapping and silently rendered unstyled.
        let stream = track.isExternal
            ? Self.registeredSidecar(
                forTrack: track, engineTracks: engine.subtitleTracks, registered: externalSubtitleStreams
            )
            : Self.jellyfinStream(
                forTrack: track, engineTracks: engine.subtitleTracks, mediaStreams: mediaStreams
            )
        guard let stream else { return nil }
        return await client.subtitleURL(
            itemID: itemID, mediaSourceID: mediaSourceID, streamIndex: stream.index, codec: stream.codec
        ).map(ASSScriptSource.remote)
    }

    /// The fonts for this source, fetched at most once per session.
    ///
    /// Coalesced through a stored `Task` rather than a "did I already?" flag:
    /// the engine re-announces the selected track on every track-list
    /// republish, and `handleSubtitleTrackChange` cancels the previous fetch
    /// without waiting for it to finish, so two of these can genuinely overlap.
    /// A flag set before the first `await` would hand the second caller an
    /// empty list; awaiting the same task hands it the same answer.
    private func resolveFetchedASSFonts() async -> [ASSFontAttachment] {
        if let assFontTask { return await assFontTask.value }
        let task = Task<[ASSFontAttachment], Never> { [weak self] in
            await self?.fetchASSFonts() ?? []
        }
        assFontTask = task
        return await task.value
    }

    /// Where the fonts an authored script names come from when AetherEngine
    /// has none — which is every route that never demuxes the original
    /// container:
    ///
    /// - **A server-side transcode.** The app plays the server's fMP4 HLS
    ///   through AVPlayer, so nothing local reads the source MKV; and MP4
    ///   carries no attachments even if it did.
    /// - **Offline.** The downloaded file is MP4 for the same reason, so
    ///   `DownloadManager` stores the attachments as sidecars at enqueue and
    ///   they are read back from disk here.
    ///
    /// Streaming, this is the `/Videos/{id}/{source}/Attachments/{index}`
    /// route. A failure is dropped rather than propagated: a missing face
    /// renders the script in a fallback one, which is how the app behaved
    /// before any of this and is not worth failing a subtitle over.
    private func fetchASSFonts() async -> [ASSFontAttachment] {
        if let downloadedItem {
            return Self.assFonts(fromDownloaded: downloadedItem.fontFiles)
        }
        guard let mediaSourceID = activeMediaSourceID else { return [] }
        var fonts: [ASSFontAttachment] = []
        // Serial rather than a task group: a container carries a handful of
        // faces (1-4 across every attachment-bearing file in the library this
        // was measured on), and each one the server has to extract is work it
        // does one job at a time anyway.
        for attachment in JellyfinAPIClient.fontAttachments(in: mediaAttachments) {
            guard !Task.isCancelled,
                  let url = await client.attachmentURL(
                      itemID: itemID, mediaSourceID: mediaSourceID, index: attachment.index
                  ) else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = Self.fontRequestTimeout
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  !data.isEmpty else { continue }
            fonts.append(ASSFontAttachment(
                // The container's own name for the face. Only ever written
                // back out to a temp file for `CTFontManagerRegisterFontsForURL`
                // — which reads the face name out of the font's own tables, not
                // the path — so a container with no name for an attachment can
                // take one derived from its index.
                filename: attachment.fileName ?? "attachment-\(attachment.index)",
                data: data
            ))
        }
        return fonts
    }

    /// Reads a download's stored font sidecars back into memory.
    ///
    /// A file that has gone missing is skipped rather than failing the set: the
    /// row and its files can diverge (a half-deleted download, a restore that
    /// brought the database back without the sidecars), and one absent face
    /// costs a fallback for that face alone.
    static func assFonts(fromDownloaded files: [DownloadedFontFile]) -> [ASSFontAttachment] {
        files.compactMap { file in
            guard let data = try? Data(
                contentsOf: DownloadFileStore.url(forRelativePath: file.relativePath)
            ) else { return nil }
            return ASSFontAttachment(filename: file.fileName, data: data)
        }
    }

    /// Shorter than `scriptRequestTimeout`, deliberately. The same on-demand
    /// extraction is behind both, but the script IS the subtitle while the
    /// fonts are only how it looks — and since the fetch no longer gates the
    /// script (see `handleSubtitleTrackChange`), a font the server is slow to
    /// produce costs nothing but itself.
    private static let fontRequestTimeout: TimeInterval = 60

    /// What this app registered for an engine subtitle track, by ordinal.
    ///
    /// The one rule behind both sidecar paths — a download's stored files and a
    /// transcode's fetched streams. Neither can be matched by id: AetherEngine
    /// assigns its own ids to the sidecars a host registers, and they share no
    /// arithmetic with `DownloadedSubtitleFile.index` or `MediaStream.index`,
    /// which are Jellyfin's. What does hold is order — the engine reports the
    /// sidecars in the order they were handed to `load(...)` — so the nth
    /// external track is the nth registered thing.
    ///
    /// Embedded tracks are excluded from the count on purpose. A downloaded MP4
    /// can carry its own, and a direct-played container certainly does;
    /// counting them shifts the ordinal exactly as a bitmap stream shifts
    /// `jellyfinStream`'s.
    ///
    /// `nil` when the track isn't one of ours, and when the two sides disagree
    /// about how many sidecars exist — a registration that silently dropped one
    /// would slide every ordinal after it, which is the difference between
    /// showing no subtitle and confidently showing the wrong one.
    static func registeredSidecar<Registered>(
        forTrack track: PlaybackTrack,
        engineTracks: [PlaybackTrack],
        registered: [Registered]
    ) -> Registered? {
        guard track.isExternal else { return nil }
        let externalTracks = engineTracks.filter(\.isExternal)
        guard externalTracks.count == registered.count,
              let ordinal = externalTracks.firstIndex(where: { $0.id == track.id }) else { return nil }
        return registered[ordinal]
    }

    /// The Jellyfin `MediaStream` an engine subtitle track came from.
    ///
    /// By ordinal rather than by id: AetherEngine numbers an embedded track by
    /// its `AVStream` index while Jellyfin numbers the same track by its own
    /// `MediaStream.index`, and the two disagree — confirmed live on two files,
    /// engine id 2 against Jellyfin index 3 on one and id 5 against index 6 on
    /// another. Both lists preserve container order, so the nth embedded ASS
    /// track on one side is the nth on the other.
    ///
    /// Both sides are filtered to embedded ASS/SSA before counting. Filtering
    /// on BOTH properties matters: a file can carry external sidecars and
    /// bitmap tracks interleaved with the ASS ones, and counting those would
    /// shift the ordinal. External tracks need no mapping at all — this app
    /// registered them from these very streams.
    ///
    /// `nil` when the track isn't an embedded ASS one, or when the two lists
    /// disagree about how many there are, which is not a case to guess at.
    static func jellyfinStream(
        forTrack track: PlaybackTrack, engineTracks: [PlaybackTrack], mediaStreams: [MediaStream]
    ) -> MediaStream? {
        let embeddedTracks = engineTracks.filter { !$0.isExternal && isAuthoredASS($0.codec) }
        guard let ordinal = embeddedTracks.firstIndex(where: { $0.id == track.id }) else { return nil }
        let embeddedStreams = mediaStreams.filter {
            $0.type == "Subtitle" && $0.isExternal != true && isAuthoredASS($0.codec)
        }
        guard ordinal < embeddedStreams.count else { return nil }
        return embeddedStreams[ordinal]
    }

    /// Whether authored ASS/SSA tracks render through libass at all.
    ///
    /// Read at each track selection rather than captured once, so the setting
    /// applies from the next selection onward without the player having to be
    /// torn down. Settings are unreachable while the player is up — it is a
    /// `fullScreenCover` and they live in a tab behind it — so that is as live
    /// as this can be observed to be.
    ///
    /// Takes its `UserDefaults` so a test can pass its own rather than mutate
    /// the shared domain, and so the UI suite's argument-domain override works
    /// unchanged.
    static func isStyledASSEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        // `object(forKey:)` rather than `bool(forKey:)`: the latter reports
        // false for "never set", which would invert the default.
        guard defaults.object(forKey: styledASSSubtitlesEnabledStorageKey) != nil else {
            return styledASSSubtitlesEnabledDefault
        }
        return defaults.bool(forKey: styledASSSubtitlesEnabledStorageKey)
    }

    static func isAuthoredASS(_ codec: String?) -> Bool {
        switch codec?.lowercased() {
        case "ass", "ssa": return true
        default: return false
        }
    }

    /// `DownloadedSubtitleFile` records no codec, but its file was named by
    /// `JellyfinAPIClient.subtitleFileExtension(forCodec:)`, so the extension is
    /// the codec.
    static func isAuthoredASSPath(_ relativePath: String) -> Bool {
        isAuthoredASS((relativePath as NSString).pathExtension)
    }

    /// Scripts are small once they exist (tens to hundreds of KB) and are
    /// fetched once per track selection, so this is a plain one-shot load
    /// rather than anything cached.
    ///
    /// The timeout is the point. Jellyfin extracts an embedded subtitle stream
    /// on demand and caches the result, so the FIRST request for a track in a
    /// large file pays for the extraction: 70.6s measured against a 4K remux
    /// here, versus 0.03s for every request after it. `URLSession`'s default
    /// 60s request timeout cuts that off just before it finishes, which reads
    /// as "this track has no styling" rather than as a timeout.
    private static let scriptRequestTimeout: TimeInterval = 180

    private static func loadScript(from source: ASSScriptSource) async -> String? {
        do {
            switch source {
            case .localFile(let url):
                return try String(contentsOf: url, encoding: .utf8)
            case .remote(let url):
                var request = URLRequest(url: url)
                request.timeoutInterval = scriptRequestTimeout
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
                return String(data: data, encoding: .utf8)
            }
        } catch {
            return nil
        }
    }

    /// The subtitle streams this app has to hand the engine as sidecars.
    ///
    /// Always the genuinely external ones — a `.srt` sitting beside the video
    /// in the library, which is nowhere inside the container.
    ///
    /// **Plus, on a server-side transcode, the container's own text tracks.**
    /// The app plays the server's HLS through AVPlayer, and that playlist
    /// carries no subtitle rendition for them, so nothing demuxes them and they
    /// vanish from the picker entirely — every embedded SubRip and ASS track,
    /// not just the styled ones. Jellyfin says so itself: asked with this app's
    /// `DeviceProfile`, it answers `deliveryMethod: "External"` for exactly
    /// those streams (and `"Encode"` for the bitmap ones it burns in), which is
    /// the server telling the client to fetch them. Confirmed against 10.11.11.
    ///
    /// The route gate is load-bearing, not caution. Direct play reports the
    /// same `"External"` for the same embedded streams, where AetherEngine has
    /// demuxed them and lists them already — registering sidecars there would
    /// show every track in the picker twice.
    ///
    /// Order is the stream list's, and is what
    /// `registeredSidecar(forTrack:engineTracks:registered:)` maps back on.
    static func externalSubtitleStreams(
        from mediaStreams: [MediaStream], isRemoteHLS: Bool
    ) -> [MediaStream] {
        mediaStreams.filter { stream in
            guard stream.type == "Subtitle" else { return false }
            if stream.isExternal == true { return true }
            return isRemoteHLS && stream.deliveryMethod == "External"
        }
    }

    /// `ExternalSubtitleSource`s for the load. `JellyfinAPIClient.subtitleURL`
    /// covers why the URL is built from ids rather than read off the stream. An
    /// unresolvable URL is skipped rather than failing the load; external
    /// subtitles are a bonus, not a requirement.
    static func externalSubtitleSources(
        itemID: String, mediaSourceID: String, streams: [MediaStream], client: JellyfinAPIClient
    ) async -> [ExternalSubtitleSource] {
        var sources: [ExternalSubtitleSource] = []
        for stream in streams {
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
