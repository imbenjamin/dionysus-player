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

    /// Skippable Intro/Outro/Recap/Preview/Commercial time ranges for this
    /// item, fetched fire-and-forget in `start()` alongside `nextEpisode` —
    /// see `loadMediaSegments(for:)`. Empty (not `nil`) both before that
    /// resolves and once resolved with zero segments; nothing downstream
    /// distinguishes the two. `endCreditsSegment` is derived from this at
    /// the same point it's set, rather than recomputed from it on every
    /// read — see that property's own doc comment.
    private(set) var mediaSegments: [PlaybackSegment] = []

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
    /// Set only via `init(downloadedItem:downloadStore:...)` — when
    /// non-nil, `start()`/`stop()`/progress reporting all route through the
    /// local-only offline paths below instead of any network call. See the
    /// offline-downloads plan's "Offline playback wiring" section.
    private let downloadedItem: DownloadedItem?
    private let downloadStore: DownloadStore?
    private var progressReportTask: Task<Void, Never>?
    /// Resolved in `start()` once `activeMediaSourceID` is known — see
    /// `supportsScrubThumbnails`/`scrubThumbnail(atSeconds:)`.
    private var trickplayProvider: TrickplayThumbnailProvider?

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
    /// The end-credits countdown's own total length right now (see
    /// `endCreditsCountdownTotalSeconds`) once this item has an end-credits
    /// segment, else the configured preference — `NextUpOverlay`'s ring
    /// needs whichever total actually governs the countdown currently in
    /// effect, not always the user's raw preference. Before
    /// `nextUpCountdownAnchorTime` has a value yet (segment not entered),
    /// falls back to the flat `endCreditsCountdownSeconds` cap as a
    /// reasonable "what it'll most likely be" default — nothing shows the
    /// ring at this point anyway, since `nextUpSecondsRemaining` is `nil`
    /// until there's an anchor to compute it from.
    var nextUpTotalCountdownSeconds: Int? {
        guard endCreditsSegment != nil else { return nextUpPreferenceStore.countdownSeconds }
        guard let total = endCreditsCountdownTotalSeconds else { return Self.endCreditsCountdownSeconds }
        return Int(total.rounded())
    }

    /// Cap on the end-credits countdown's length — see
    /// `nextUpSecondsRemaining`'s doc comment for why this replaces the
    /// user's configured preference entirely once an end-credits segment
    /// exists, rather than combining with it.
    private static let endCreditsCountdownSeconds = 10

    /// The `.outro`-typed segment nearest this item's end (the last one
    /// chronologically, if there's more than one) — Jellyfin has no
    /// separate "opening credits" vs. "closing credits" segment type, so an
    /// item with, say, a mid-content credits roll *and* true end credits
    /// reports two `.outro` segments; only the later one is "the end
    /// credits" for `nextUpSecondsRemaining`'s override below. `nil` when
    /// this item has no `.outro` segment at all (most content, and any
    /// item `mediaSegments` hasn't resolved for yet).
    ///
    /// Cached by `loadMediaSegments(for:)` at the same moment it sets
    /// `mediaSegments`, rather than a computed property re-deriving this
    /// with a fresh `.filter{}.max{}` pass on every read — this is read
    /// from `updateNextUpCountdownAnchor()` on *every* engine time-update
    /// tick (~10x/sec, for the whole session, not just near the credits),
    /// plus once or twice more per render from `nextUpSecondsRemaining`/
    /// `nextUpTotalCountdownSeconds`/`currentSkipSegment`. `mediaSegments`
    /// is set exactly once and never mutated afterward, so there's only
    /// ever one moment this can actually change — computing it there and
    /// reusing the cached value everywhere else is free of any staleness
    /// risk.
    private var endCreditsSegment: PlaybackSegment?

    /// The playhead value the end-credits countdown is currently timed
    /// from — distinct from `endCreditsSegment.startSeconds` itself
    /// specifically to fix a live bug (2026-08-18, confirmed with the
    /// user): scrubbing straight to a point already past where a
    /// from-the-segment's-own-start countdown would have finished computed
    /// an already-negative (clamped-to-`0`) `remaining` on landing, which
    /// silently auto-advanced to the next episode with no countdown UI
    /// ever shown. `updateNextUpCountdownAnchor()` sets this the moment
    /// `currentTime` (re-)enters the segment — from natural playback *or*
    /// a scrub/seek landing inside it — and `seek(to:)` clears it
    /// unconditionally first, so any explicit jump (the scrubber, the
    /// rewind/forward buttons, VoiceOver's adjustable action) always
    /// re-anchors fresh at wherever it actually lands, rather than reusing
    /// a stale anchor from before the jump. `nil` whenever `currentTime`
    /// is outside the segment.
    private var nextUpCountdownAnchorTime: TimeInterval?

    /// `endCreditsCountdownSeconds` (10s), capped to however much of the
    /// item's own duration remains from the anchor — so a segment (or a
    /// scrub landing) within the final 10 seconds of the item counts down
    /// to reach exactly `0` right at the asset's true end, rather than
    /// implying a target past it. `nil` before there's an anchor to
    /// compute from.
    private var endCreditsCountdownTotalSeconds: Double? {
        guard let anchor = nextUpCountdownAnchorTime else { return nil }
        return max(0, min(Double(Self.endCreditsCountdownSeconds), duration - anchor))
    }

    /// Called from `onTimeUpdate` on every engine time tick — see
    /// `nextUpCountdownAnchorTime`'s doc comment. Purely a "rising edge"
    /// detector: once set, the anchor is left alone as `currentTime`
    /// progresses naturally forward through the segment (letting a live
    /// countdown actually count down and complete), and only re-derived
    /// when `currentTime` (re-)enters the segment from outside it — which
    /// `seek(to:)` engineers to be true again immediately after any
    /// explicit jump, by clearing the anchor first.
    private func updateNextUpCountdownAnchor() {
        guard let endCreditsSegment, currentTime >= endCreditsSegment.startSeconds else {
            nextUpCountdownAnchorTime = nil
            return
        }
        if nextUpCountdownAnchorTime == nil {
            nextUpCountdownAnchorTime = currentTime
        }
    }

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
    ///
    /// Also suppressed for as long as `isPictureInPictureActive` is true —
    /// found live (2026-08-17): auto-advancing while in PiP tears down
    /// `AetherPlaybackEngine` (and with it, the `AVPictureInPictureController`
    /// it owns), closing the user's PiP window out from under them with no
    /// guarantee it comes back (auto-PiP only re-triggers on a fresh
    /// foreground→background transition, so a next episode that mounts
    /// while already backgrounded just plays invisibly). `NextUpOverlay`
    /// is already fully covered by `PictureInPictureOverlay`'s own
    /// placeholder while PiP is active — see `PlayerView`'s ZStack — so
    /// this just makes the underlying state match what's already true on
    /// screen, rather than actually freezing/resuming anything: the moment
    /// PiP ends, this recomputes fresh from wherever `duration`/`currentTime`
    /// actually are, same as it would after being dismissed for any other
    /// reason above.
    ///
    /// **End-credits override:** when this item has an `endCreditsSegment`,
    /// that segment's start time fully replaces the duration-relative
    /// trigger above — the configured `countdownSeconds` preference plays
    /// no role in *when* this fires once such a segment exists, only in
    /// *whether* Up Next is enabled at all. The card appears the instant
    /// the segment starts and counts down `endCreditsCountdownTotalSeconds`
    /// from there, regardless of how that compares to the preference
    /// window: a segment starting later than the preference would have
    /// fired stays hidden until the segment itself starts (no early
    /// duration-relative fallback), and one starting earlier fires right
    /// then rather than waiting for the preference's own window. Confirmed
    /// with the user (2026-08-17) this is the intended behavior in both
    /// directions, not just "whichever fires first."
    ///
    /// The countdown is timed from `nextUpCountdownAnchorTime`, not
    /// `endCreditsSegment.startSeconds` directly — see that property's own
    /// doc comment for the scrub-landing-past-the-trigger-point bug
    /// (2026-08-18) this distinction fixes.
    ///
    /// Truncates (`Int(remaining)`) rather than rounding up — confirmed
    /// live (2026-08-18): rounding up made this consistently read one
    /// *higher* than the scrubber's own "time remaining" label
    /// (`PlayerControlsOverlay.endTimeText`/`formatTime`, which truncates),
    /// since a fractional `remaining` almost never lands on an exact whole
    /// second — e.g. landing a scrub where the scrubber itself reads "0:06"
    /// remaining (truncating anything in `[6, 7)`) showed `7` here instead
    /// of `6` whenever the true remaining time was, say, `6.4s`. Truncating
    /// here instead matches that convention. `max(0, ...)` below still
    /// covers the clamp-at-`0` case documented above unchanged — a negative
    /// `remaining` truncates to a negative `Int` same as it rounded to one.
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

    /// Segment ids `skipSegment(_:)` has already been called for — see that
    /// method's doc comment. Sticks for the rest of this item's playback,
    /// same "once acted on, don't resurrect it" treatment `isNextUpDismissed`
    /// gives the Up Next card's Cancel button.
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
        /// Non-nil routes this whole session through the offline playback
        /// path — see `downloadedItem`'s own doc comment. `itemID` should
        /// still be `downloadedItem.itemID` in that case (the same
        /// Jellyfin item id, just played from a local file); `client`/
        /// `userID` are still required and still valid to pass through
        /// even offline (nothing here calls them unless reconnected), so
        /// callers don't need a separate offline-only initializer shape.
        downloadedItem: DownloadedItem? = nil,
        downloadStore: DownloadStore? = nil
    ) {
        self.client = client
        self.userID = userID
        self.itemID = itemID
        self.engine = engine
        self.startFromBeginning = startFromBeginning
        self.requestedMediaSourceID = mediaSourceID
        self.trackPreferenceStore = trackPreferenceStore
        self.nextUpPreferenceStore = nextUpPreferenceStore
        self.downloadedItem = downloadedItem
        self.downloadStore = downloadStore

        engine.onStateChange = { [weak self] state in
            guard let self else { return }
            self.state = state
            // A terminal engine failure used to be silent: `state` updated,
            // but nothing derived `errorMessage` from it, so the video just
            // froze on its last frame with no spinner and no message — the
            // only place `.failed` was ever visible was the diagnostics-only
            // "stats for nerds" overlay. `PlayerView`'s error overlay reads
            // `errorMessage`, so it needs to actually be set here too, not
            // just from `start()`'s own `catch`.
            if case .failed(let message) = state {
                self.progressReportTask?.cancel()
                self.errorMessage = message
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

    /// - Parameter resumeSeconds: When provided, seeks here after loading
    ///   instead of consulting `mediaItem.resumePositionSeconds` (the
    ///   server's last-known position, which may be stale/unrelated) —
    ///   used to resume in place after a connectivity-loss retry, where
    ///   the caller already knows exactly where playback stopped.
    func start(resumeSeconds: TimeInterval? = nil) async {
        errorMessage = nil
        if let downloadedItem {
            await startOffline(downloadedItem, resumeSeconds: resumeSeconds)
            return
        }
        do {
            let images = await client.makeImageURLBuilder()
            // `detailFieldsWithTrickplay`, not the plain default — this is
            // the one caller of `item(userID:itemID:)` that actually needs
            // `Trickplay` (for `trickplayProvider` below); see that
            // parameter's own doc comment for why the shared default
            // doesn't carry it for every other caller too.
            let dto = try await client.item(userID: userID, itemID: itemID, fields: JellyfinAPIClient.detailFieldsWithTrickplay)
            let mediaItem = MediaItem(dto: dto, images: images)
            item = mediaItem
            // Title/subtitle land immediately so the lock screen/Control
            // Center have *something* as soon as this resolves — artwork
            // trails in separately once fetched (see
            // `loadNowPlayingArtwork(for:)`), rather than blocking on it.
            engine.setNowPlayingInfo(title: mediaItem.railTitle, subtitle: mediaItem.railSubtitle, artwork: nil)
            loadNowPlayingArtwork(for: mediaItem)
            loadNextEpisode(for: mediaItem, images: images)
            loadMediaSegments(for: mediaItem)

            let playbackInfo = try await client.playbackInfo(itemID: itemID, userID: userID, mediaSourceID: requestedMediaSourceID)
            // The requested id might not match anything (stale preference
            // for a version since removed from the server, say) — fall back
            // to the server's own default rather than failing outright.
            let source = requestedMediaSourceID.flatMap { id in playbackInfo.mediaSources?.first { $0.id == id } }
                ?? playbackInfo.mediaSources?.first
            activeMediaSourceID = source?.id
            sourceVideoStream = source?.mediaStreams?.first { $0.type == "Video" }
            if let mediaSourceID = activeMediaSourceID,
               let info = TrickplayMath.bestInfo(from: mediaItem.dto.trickplay, mediaSourceID: mediaSourceID) {
                trickplayProvider = TrickplayThumbnailProvider(itemID: itemID, info: info, imageURLBuilder: images)
            }

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
            // An explicit `resumeSeconds` (connectivity-loss retry, resuming
            // exactly where playback stopped) always wins over the server's
            // last-known resume position and ignores `startFromBeginning` —
            // this is recovering an already-started session, not honoring
            // an intentional "play from the top" request.
            if let resumeSeconds, resumeSeconds > 0 {
                await engine.seek(to: resumeSeconds)
            } else if !startFromBeginning, let resumeSeconds = mediaItem.resumePositionSeconds, resumeSeconds > 0 {
                await engine.seek(to: resumeSeconds)
            }
            engine.play()

            try? await client.reportPlaybackStart(itemID: itemID, mediaSourceID: activeMediaSourceID)
            startProgressReporting()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? String(localized: "Playback failed to start.")
        }
    }

    /// Offline counterpart to the network path above — see `downloadedItem`'s
    /// doc comment and the offline-downloads plan's "Offline playback
    /// wiring" section. Builds a `file://` playback URL and local
    /// `ExternalSubtitleSource`s from `DownloadFileStore` instead of
    /// `client.streamURL`/`subtitleURL`, and skips every network call
    /// `start()` makes (item fetch, `playbackInfo`, `reportPlaybackStart`,
    /// next-episode lookup — none of which have anything to fetch offline;
    /// `nextEpisode` simply stays `nil`, same as any item whose lookup
    /// fails today) in favor of the download's own stored snapshot
    /// (`mediaSegments`, resume position). Progress/stop route to
    /// `writeOfflineProgress(_:)` instead of `reportPlaybackProgress`/
    /// `reportPlaybackStopped`.
    ///
    /// `item` is still populated — with a synthetic `MediaItem` built from
    /// an otherwise-empty `BaseItemDto` carrying just the stored title/
    /// episode info — purely so `PlayerControlsOverlay`'s existing title
    /// row keeps working unmodified: no `imageTags` means
    /// `logoImageURL`/`primaryImageURL` all resolve to `nil`, which that
    /// view already renders as a plain title-text fallback (the same path
    /// a live item with no logo takes) rather than attempting a network
    /// image fetch against a placeholder URL.
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
        // Any placeholder base URL works: with no `imageTags` on `dto`
        // above, nothing this builder is capable of building ever actually
        // gets requested — see this method's own doc comment.
        let mediaItem = MediaItem(dto: dto, images: ImageURLBuilder(baseURL: URL(string: "https://offline.invalid")!))
        item = mediaItem
        engine.setNowPlayingInfo(title: mediaItem.railTitle, subtitle: mediaItem.railSubtitle, artwork: nil)

        activeMediaSourceID = downloadedItem.mediaSourceID
        mediaSegments = downloadedItem.segments.map(PlaybackSegment.init(downloaded:))
        endCreditsSegment = mediaSegments.filter { $0.kind == .outro }.max { $0.startSeconds < $1.startSeconds }

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
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? String(localized: "Playback failed to start.")
        }
    }

    /// Fraction of the item played at which offline playback considers it
    /// "watched" — there's no server to make this judgement call the way
    /// `reportPlaybackStopped` normally defers to (see that call's doc
    /// comment elsewhere in this app), so this is a client-side stand-in.
    /// 90% matches Jellyfin server's own common default resume/played
    /// threshold.
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

    /// Writes local resume/watched state directly onto the `DownloadedItem`
    /// row and marks it `pendingSync` — the offline counterpart to
    /// `reportPlaybackProgress`/`reportPlaybackStopped`, which this path
    /// must never depend on network for. `DownloadSyncManager` is what
    /// eventually pushes this to the server, once reconnected.
    private func writeOfflineProgress(_ downloadedItem: DownloadedItem) {
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
        // The real, on-device moment this actually happened — see
        // `DownloadedItem.lastPlayedAt`'s doc comment for why this has to
        // be captured here (while it's genuinely happening, possibly
        // fully offline) rather than left for the server to infer once
        // `DownloadSyncManager` eventually reaches it, which could be
        // hours or days later.
        downloadedItem.lastPlayedAt = Date()
        downloadedItem.pendingSync = true
        downloadStore?.save()
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

    /// Fire-and-forget, same shape as `loadNextEpisode(for:images:)`:
    /// resolves `mediaSegments` via `JellyfinAPIClient.mediaSegments(itemID:)`.
    /// Unlike `loadNextEpisode`, this isn't episode-only — movies get
    /// Skip Intro/Recap/etc. too. A failed fetch (including an older server
    /// that doesn't support the Media Segments feature at all) just leaves
    /// `mediaSegments` empty, the same "bonus, not a requirement" treatment
    /// external subtitles and `nextEpisode` already get.
    ///
    /// Also derives `endCreditsSegment` here, alongside `mediaSegments`
    /// itself — see that property's own doc comment for why it's cached at
    /// this single point rather than recomputed from `mediaSegments` on
    /// every read.
    private func loadMediaSegments(for item: MediaItem) {
        Task { [weak self] in
            guard let dtos = try? await self?.client.mediaSegments(itemID: item.id) else { return }
            let segments = dtos.compactMap(PlaybackSegment.init(dto:))
            self?.mediaSegments = segments
            self?.endCreditsSegment = segments.filter { $0.kind == .outro }.max { $0.startSeconds < $1.startSeconds }
        }
    }

    /// `SkipSegmentOverlay`'s button — records the segment as skipped (see
    /// `skippedSegmentIDs`, which immediately hides its button via
    /// `currentSkipSegment` rather than waiting for the seek below to
    /// actually land) and jumps to the end of the segment, reusing
    /// `seek(to:)` verbatim.
    func skipSegment(_ segment: PlaybackSegment) {
        skippedSegmentIDs.insert(segment.id)
        seek(to: segment.endSeconds)
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

    /// Clears `nextUpCountdownAnchorTime` unconditionally before issuing
    /// the seek — see that property's own doc comment for why every
    /// explicit jump (this is the one choke point all of them go through:
    /// the scrubber, the rewind/forward buttons, VoiceOver's adjustable
    /// action) needs to force a fresh end-credits countdown anchor at
    /// wherever it lands, rather than risk reusing a stale one from before
    /// the jump.
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

    /// `true` once `start()` has resolved a Jellyfin trickplay track for
    /// the active media source — `PlayerControlsOverlay` gates the
    /// scrub-preview bubble on this, same "self-disable, don't show
    /// broken" treatment `onPictureInPicturePossibleChange` gives the PiP
    /// button. `false` for content Jellyfin hasn't scanned for trickplay
    /// yet, same as before `start()` has resolved anything at all.
    var supportsScrubThumbnails: Bool { trickplayProvider != nil }

    /// Thin passthrough to `trickplayProvider.thumbnail(atSeconds:)` — see
    /// `TrickplayThumbnailProvider`'s doc comment for the nil/"keep showing
    /// the last still" contract callers should follow (rare here — a miss
    /// only happens on a request/decode failure, not a "not resident yet"
    /// case the way AetherEngine's cache-backed version had).
    func scrubThumbnail(atSeconds seconds: Double) async -> CGImage? {
        await trickplayProvider?.thumbnail(atSeconds: seconds)
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
        if let downloadedItem {
            engine.stop()
            writeOfflineProgress(downloadedItem)
            return
        }
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
