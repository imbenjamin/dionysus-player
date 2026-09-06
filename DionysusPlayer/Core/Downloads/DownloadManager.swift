import AVFoundation
import Foundation
import Observation

/// Live progress for one in-flight download — what `DownloadsView`/
/// `DownloadButton` bind to. Kept in memory only, not persisted per tick (a
/// SwiftData write on every `didWriteData` callback would be dozens of
/// writes a second) — the row's own fields are updated once, at completion.
struct DownloadProgress: Equatable {
    var bytesDownloaded: Int64
    /// The server never reports a real `Content-Length` for this
    /// live-transcode stream (`Static=false`), so this is usually
    /// `DownloadedItem.estimatedTotalBytes` — a bitrate/runtime estimate
    /// computed once at enqueue time — rather than anything the transfer
    /// itself reported. `<= 0` only when even that estimate couldn't be
    /// computed.
    var totalBytesExpected: Int64
    /// Jellyfin's own live `TranscodingInfo.CompletionPercentage` (0...100)
    /// for this item's active transcode job, polled separately by
    /// `DownloadManager.startTranscodeProgressPolling` — real encode-timeline
    /// progress (ffmpeg's own position against the source's total duration),
    /// immune to the content-adaptive-bitrate variance that makes
    /// `bytesDownloaded`/`totalBytesExpected` alone run anywhere from ~46%
    /// to ~95% "full" by the time a transcode actually finishes (see
    /// DOWNLOADS.md's "Content-adaptive spread, in the wild"). `nil` for a
    /// stream-copy download (no transcode job exists to report on), before
    /// the first poll response arrives, or for a download reattached after
    /// a relaunch (polling needs a live signed-in client, which isn't
    /// available that early — see that method's doc comment).
    var transcodeCompletionPercentage: Double? = nil

    var isTotalKnown: Bool { totalBytesExpected > 0 }

    /// Whether `fractionCompleted` reflects a real number rather than a
    /// hardcoded `0` — either source counts.
    var isDeterminate: Bool { transcodeCompletionPercentage != nil || isTotalKnown }

    /// The fraction actually shown, from whichever source is available —
    /// `transcodeCompletionPercentage` preferred over the byte estimate when
    /// present (see its own doc comment) — and, either way, capped just
    /// short of full: real completion is only ever signalled by the
    /// transfer's own completion callback, never by this number, so it must
    /// not visually read "done" a tick before that actually fires (a real
    /// transcode's output can be smaller than predicted and finish while
    /// the byte estimate is still well under 100%, or the completion
    /// percentage can round to 100 slightly before the last bytes actually
    /// land).
    var fractionCompleted: Double {
        let raw: Double
        if let transcodeCompletionPercentage {
            raw = transcodeCompletionPercentage / 100
        } else if isTotalKnown {
            raw = Double(bytesDownloaded) / Double(totalBytesExpected)
        } else {
            return 0
        }
        return min(0.99, max(0, raw))
    }

    /// "Downloading… 42%" whenever there's a number to show (byte estimate
    /// or live transcode percentage), "Downloading… 128 MB" (bytes
    /// transferred so far, the only number there is) when there isn't.
    var statusText: String {
        if isDeterminate {
            return String(localized: "Downloading… \(Int((fractionCompleted * 100).rounded()))%")
        }
        let downloaded = ByteCountFormatter.string(fromByteCount: bytesDownloaded, countStyle: .file)
        return String(localized: "Downloading… \(downloaded)")
    }
}

enum DownloadError: LocalizedError {
    case missingMediaSource
    case invalidDownloadURL
    /// `retry(itemID:client:)`-specific — the item was removed from the
    /// server (or the library it was in) since it was originally
    /// downloaded, so there's nothing left to re-fetch.
    case itemNoLongerAvailable
    /// AUDIO SUPPRESSION: see `enqueue(...)`'s guard. Delete this case once
    /// Dionysus Player supports downloading audio/music content.
    case audioContentNotSupported

    var errorDescription: String? {
        switch self {
        case .missingMediaSource: return String(localized: "This item has no downloadable media source.")
        case .invalidDownloadURL: return String(localized: "Couldn't build a download URL for this item.")
        case .itemNoLongerAvailable: return String(localized: "This item is no longer available on the server.")
        case .audioContentNotSupported: return String(localized: "Audio and music items can't be downloaded.")
        }
    }
}

/// Downloads/deletes offline copies of Jellyfin items — device-transcoded
/// video, sidecar subtitles, and a metadata/artwork snapshot, all via
/// `DownloadFileStore`/`DownloadStore`. See the offline-downloads plan for
/// the full design.
@MainActor
@Observable
final class DownloadManager: NSObject {
    private(set) var activeDownloads: [String: DownloadProgress] = [:]

    /// Rows not yet finished — what `MainTabView`'s Downloads tab badge
    /// shows. Reads `store.changeCount` (see that property's own doc
    /// comment) rather than `activeDownloads`, so it also counts a
    /// `.queued` row still waiting for a concurrency slot, which never
    /// appears in `activeDownloads` at all. `.paused` is included even
    /// though nothing currently sets it (see `DownloadStatus`) — it belongs
    /// in the same "still needs attention" bucket as `.queued`/
    /// `.downloading`, not with `.completed`/`.failed`.
    var pendingOrActiveDownloadsCount: Int {
        _ = store.changeCount
        let pendingStatuses: Set<DownloadStatus> = [.queued, .downloading, .paused]
        return store.visibleItems().filter { pendingStatuses.contains($0.status) }.count
    }

    /// Fired from `delete(itemID:)` right after a row survives as
    /// `markedForDeletion`, to nudge `DownloadSyncManager` immediately
    /// rather than waiting for the next scenePhase trigger. A closure
    /// rather than a stored `client` because, unlike `AppState.apiClient`,
    /// this manager is never recreated across sign-in/sign-out/server
    /// changes — a stored client would go stale. `nil` is a safe no-op.
    var onRowMarkedForDeletion: (() -> Void)?

    /// Not `private` — the Downloads UI reads directly from this rather
    /// than a growing set of pass-through methods; this type still owns
    /// every *write* path (`enqueue`/`delete`).
    let store: DownloadStore
    /// The app's **one** background session identifier. See
    /// `DownloadTaskRouter`'s doc comment for the -997 ("Lost connection to
    /// the background transfer service") bug that collapsing to a single
    /// session fixes, and why a session per item made downloads fragile in
    /// proportion to how many passed through the queue.
    private static let backgroundSessionIdentifier = "com.dionysus.downloads"
    /// The identifiers the *previous* (session-per-item) scheme handed out.
    /// Retained only so `sweepLegacyPerItemSessions` can reclaim sessions
    /// left live in `nsurlsessiond` by a build that predates the single-session
    /// change, and so a background relaunch delivering events for one of them
    /// can still answer UIKit's completion handler. Delete both this and its
    /// two call sites once a couple of releases have shipped — by then no
    /// device can still be carrying one.
    private static let legacyPerItemSessionIdentifierPrefix = "com.dionysus.downloads."
    /// Applies both to the initial warm-up (Jellyfin transcode jobs need a
    /// moment before streaming bytes back) and to any later gap in the
    /// stream — `URLSessionConfiguration.timeoutIntervalForRequest` resets
    /// on every received chunk, it isn't a one-shot connect timeout. Raised
    /// from 60s (2026-08-27): a real, transient stall under
    /// concurrent-download CPU contention could exceed 60s on its own,
    /// which tore down this client's own connection well before it had any
    /// chance to matter — see `startTranscodeProgressPolling`'s doc comment
    /// for the fuller, confirmed-live chain this was one link in. Deliberately
    /// still finite, not `.infinity`: a genuinely dead connection (server
    /// down, network gone) should still fail within a bounded time rather
    /// than hang until `downloadResourceTimeout`.
    private static let downloadRequestTimeout: TimeInterval = 120
    /// Bounds the whole resource fetch, not just the warm-up above — a 4K
    /// transcode can run for a long time.
    private static let downloadResourceTimeout: TimeInterval = 60 * 60 * 6
    /// How many trickplay tile-sheet JPEGs `downloadTrickplayTiles` fetches
    /// at once — bounded so it doesn't compete too hard with the video
    /// transcode over the same connection.
    private static let maxConcurrentTrickplaySheetDownloads = 4

    /// Used for the small ad-hoc fetches alongside a download (subtitles,
    /// artwork, trickplay tiles) instead of `URLSession.shared` — those
    /// went through `.shared` unconditionally before, which meant
    /// `DownloadPreferencesStore.wifiOnly` only ever gated the video
    /// transfer itself, not these.
    ///
    /// **One session, built once.** This used to be a *computed* property
    /// that constructed a brand-new `URLSession` on every single access,
    /// so that a mid-session `wifiOnly` change would be honored — and
    /// nothing ever invalidated any of them. `downloadImageIfNeeded` alone
    /// reads it four times per enqueue (poster/backdrop/logo/thumb), on top
    /// of one each for subtitles, trickplay and chapters, so a ten-episode
    /// season download leaked dozens of live sessions and their connection
    /// pools. The Wi-Fi gate moved to the *request* instead
    /// (`makeFetchRequest(url:)`), which is both cheaper and strictly more
    /// correct: `URLRequest.allowsCellularAccess` is evaluated per request,
    /// so a preference change is picked up by the very next fetch rather
    /// than only by the next session, and `allowsExpensiveNetworkAccess`
    /// lets it also cover a personal hotspot — which the configuration-level
    /// flag alone never did.
    private let adHocFetchSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        // Always permitted at the session level; the real gate is per-request
        // (see this property's own doc comment and `makeFetchRequest`).
        configuration.allowsCellularAccess = true
        #if DEBUG
        UITestHarness.decorate(configuration)
        #endif
        return URLSession(configuration: configuration)
    }()

    /// Applies `DownloadPreferencesStore.wifiOnly` to one request. The
    /// effective policy for a transfer is the AND of its session's
    /// configuration and its own request's flags, so gating here alone is
    /// enough — and unlike a configuration flag it can be re-evaluated for
    /// every fetch against a single long-lived session.
    /// `allowsExpensiveNetworkAccess` is what actually covers a personal
    /// hotspot (iOS reports one as expensive rather than as cellular), which
    /// "Wi-Fi Only" plainly ought to exclude and previously didn't.
    private func makeFetchRequest(url: URL) -> URLRequest {
        Self.makeFetchRequest(url: url, allowsCellularAccess: !preferences.wifiOnly)
    }

    /// `nonisolated static` so `downloadChapterImages`/`downloadTrickplayTiles`'
    /// task groups can build requests without hopping back to this
    /// `@MainActor` type — the same reason those methods already hoist the
    /// session itself. Not `private`: `DownloadManagerTests` asserts on the
    /// returned request directly, which is what replaced the old
    /// assertions against `makeBackgroundConfiguration`'s
    /// `allowsCellularAccess`.
    nonisolated static func makeFetchRequest(url: URL, allowsCellularAccess: Bool) -> URLRequest {
        var request = URLRequest(url: url)
        request.allowsCellularAccess = allowsCellularAccess
        request.allowsExpensiveNetworkAccess = allowsCellularAccess
        return request
    }

    /// The single delegate behind `backgroundSession`, retained here since
    /// a `URLSession` releases its delegate when invalidated and this one is
    /// never invalidated at all.
    private let router = DownloadTaskRouter()
    /// The app's one background `URLSession`, built on first use and kept
    /// for the process lifetime — never invalidated, by design. `lazy` so
    /// that a unit test driving the queue through `startVideoDownloadOverride`,
    /// and a UI test run that never downloads, don't construct one at all.
    /// `@ObservationIgnored` because `@Observable` rewrites every stored
    /// property into a tracked one, and a tracked property can't be `lazy` —
    /// nothing observes a `URLSession` anyway.
    @ObservationIgnored private lazy var backgroundSession: URLSession = {
        URLSession(configuration: Self.makeBackgroundConfiguration(), delegate: router, delegateQueue: nil)
    }()
    /// Item IDs whose video transfer is actually running right now — "how
    /// many downloads are in flight" for `canStartAnotherDownload`, and the
    /// once-only gate that makes completion handling idempotent.
    ///
    /// This used to be inferred from `delegates.count`, a dictionary of
    /// per-download delegate objects. With one shared router there is no
    /// per-item delegate left to count, and a set of item IDs says what it
    /// means rather than needing three paragraphs to defend counting
    /// something else.
    private var activeItemIDs: Set<String> = []
    /// Live download tasks keyed by itemID, so `delete(itemID:)` can cancel
    /// an in-flight transfer. A cache, never the source of truth — that is
    /// the session's own task list, which is why `delete` also sweeps
    /// `getAllTasks` for anything adopted at launch but not yet recorded here.
    private var downloadTasks: [String: URLSessionDownloadTask] = [:]
    /// Stashed by a background relaunch (`handleBackgroundSessionEvents`),
    /// called once the session reports every queued callback delivered.
    /// Singular, unlike the per-item dictionary the session-per-item scheme
    /// needed — and answering it is now unconditional, closing the several
    /// paths on which a handler used to be stashed and then never called
    /// (which costs the app background time on the next launch).
    private var backgroundCompletionHandler: (() -> Void)?
    /// Item IDs waiting for a concurrency slot, FIFO, popped from the front
    /// by `admitQueuedDownloadsIfPossible`. Not the same as "every
    /// `.queued` row": an item can be `.queued` and not yet in here, for
    /// the brief window `enqueue` spends fetching subtitle sidecars first.
    private var pendingQueue: [String] = []
    /// Live-transcode-progress poll loops, keyed by itemID — see
    /// `startTranscodeProgressPolling`. Cancelled (and removed) whenever a
    /// download finishes, fails, or is deleted.
    private var transcodeProgressPollTasks: [String: Task<Void, Never>] = [:]
    /// Deferred `startTranscodeProgressPolling` calls, keyed by itemID —
    /// staged by `enqueue` and fired by `admitQueuedDownloadsIfPossible` the
    /// moment the item actually starts transferring.
    ///
    /// `enqueue` used to start the loop itself, for every item, the instant
    /// it was queued — including the ones still sitting behind
    /// `maxConcurrentDownloads` with no transfer and therefore no server-side
    /// transcode job in existence yet. Two real consequences, both worse the
    /// more items are queued (a season download being the normal case): every
    /// waiting item pinged `/Sessions/Playing/Ping` every two seconds for a
    /// `PlaySessionId` the server had never heard of, and — because the loop
    /// only trusts the device's single shared `TranscodingInfo` while
    /// `transcodeProgressPollTasks.count == 1` — merely *queueing* anything
    /// permanently suppressed the live completion percentage for the one
    /// download that was genuinely running, falling the whole UI back to the
    /// byte estimate.
    ///
    /// A closure rather than the `playSessionId`/`client` pair it captures:
    /// it keeps the client alive only for as long as this item is queued or
    /// downloading, which is what lets this type go on never storing a
    /// long-lived `JellyfinAPIClient` of its own (see `onRowMarkedForDeletion`).
    private var pendingPollStarters: [String: () -> Void] = [:]
    /// How often `startTranscodeProgressPolling` both re-checks `/Sessions`
    /// and sends its keep-alive ping — frequent enough that the on-screen
    /// percentage moves visibly and comfortably inside Jellyfin's 10-second
    /// kill-timer window (see that method's doc comment), infrequent enough
    /// not to compete meaningfully with the transcode itself over the
    /// connection.
    private static let transcodeProgressPollInterval: Duration = .seconds(2)
    /// How many times each item's transfer has been re-armed automatically
    /// after a *transport* failure (see `isRetryableTransportError`), and the
    /// scheduled re-arms themselves.
    ///
    /// Deliberately in memory rather than persisted on `DownloadedItem`. A
    /// defaulted stored property would have been a lightweight SwiftData
    /// migration and no more (`chapters` is the precedent), so cost isn't
    /// the argument — semantics are. The budget bounds one *automatic* loop,
    /// and the fault it exists for is a process/daemon-lifetime one. A user
    /// reopening the app the next day should get fresh attempts, not inherit
    /// an exhausted counter from a bad afternoon — which would make the
    /// feature weakest in exactly the launch-adoption case it's most needed
    /// for. The accepted trade-off: a genuinely hopeless item can spend its
    /// budget once per launch. Bounded, logged, and the row still lands
    /// visibly `.failed` each time, so it can never loop silently.
    private var automaticRetryAttempts: [String: Int] = [:]
    private var retryTasks: [String: Task<Void, Never>] = [:]
    /// Backoff between automatic re-arms; its `count` is also the budget.
    /// The first step is deliberately short — comfortably inside Jellyfin's
    /// 10-second transcode kill timer (see `startTranscodeProgressPolling`),
    /// so a re-arm can reattach to the still-running job rather than
    /// provoking a fresh encode from byte zero. Injectable so tests can
    /// drive the budget without actually waiting.
    private let automaticRetryBackoff: [Duration]
    /// Injectable so `DownloadManagerTests` can drive
    /// `maxConcurrentDownloads` directly rather than mutating
    /// `UserDefaults.standard`.
    private let preferences: DownloadPreferencesStore
    /// Test-only DI seam: lets `DownloadManagerTests` verify
    /// `admitQueuedDownloadsIfPossible`'s FIFO/concurrency bookkeeping
    /// without a real network call or background session. Passed into
    /// `init` so it's in place before `resumePendingQueue()` can use it.
    private let startVideoDownloadOverride: ((String, URL, String) -> Void)?
    /// Test-only DI seam: when set, `delete(itemID:)` calls this instead of
    /// cancelling the item's real download task.
    private let cancelVideoDownloadOverride: ((String) -> Void)?
    /// Test-only DI seam: when set, `adoptInFlightDownloads` calls this
    /// instead of sweeping the real background `URLSession`'s task list.
    private let reattachVideoDownloadOverride: ((String) -> Void)?

    init(
        store: DownloadStore,
        preferences: DownloadPreferencesStore = DownloadPreferencesStore(),
        automaticRetryBackoff: [Duration] = [.seconds(2), .seconds(8), .seconds(20)],
        startVideoDownloadOverride: ((String, URL, String) -> Void)? = nil,
        cancelVideoDownloadOverride: ((String) -> Void)? = nil,
        reattachVideoDownloadOverride: ((String) -> Void)? = nil
    ) {
        self.store = store
        self.preferences = preferences
        self.automaticRetryBackoff = automaticRetryBackoff
        self.startVideoDownloadOverride = startVideoDownloadOverride
        self.cancelVideoDownloadOverride = cancelVideoDownloadOverride
        self.reattachVideoDownloadOverride = reattachVideoDownloadOverride
        super.init()
        router.onProgress = { [weak self] itemID, downloaded, expected in
            self?.handleDownloadProgress(itemID: itemID, downloaded: downloaded, expected: expected)
        }
        router.onCompletion = { [weak self] itemID, result in
            self?.handleDownloadCompletion(itemID: itemID, result: result)
        }
        router.onFinishedEvents = { [weak self] in
            self?.answerBackgroundCompletionHandler()
        }
        NotificationCenter.default.addObserver(
            forName: .dionysusHandleBackgroundURLSession, object: nil, queue: .main
        ) { [weak self] notification in
            guard let identifier = notification.userInfo?[DionysusBackgroundURLSessionUserInfoKey.identifier] as? String,
                  let box = notification.userInfo?[DionysusBackgroundURLSessionUserInfoKey.completionHandler] as? BackgroundSessionCompletionBox
            else { return }
            // `queue: .main` above already guarantees this runs on the main
            // thread — `MainActor.assumeIsolated` asserts that rather than
            // hopping through a new `Task`.
            MainActor.assumeIsolated {
                self?.handleBackgroundSessionEvents(identifier: identifier, completionHandler: box.handler)
            }
        }
        // Sweeps up files left behind by a row that's gone but whose
        // download task kept writing after — see
        // `DownloadFileStore.deleteOrphanedItemDirectories`.
        DownloadFileStore.deleteOrphanedItemDirectories(knownItemIDs: Set(store.allItems().map(\.itemID)))
        // Must run before `resumePendingQueue()` — it reserves in-flight
        // rows' concurrency slots first, so the queue's own admission pass
        // doesn't overshoot the configured limit.
        sweepLegacyPerItemSessions()
        adoptInFlightDownloads()
        resumePendingQueue()
    }

    convenience override init() {
        self.init(store: .makeDefault())
    }

    // MARK: - Enqueue

    /// `mediaSource`/`audioTrack`/`subtitleTracks` are whatever the caller
    /// (`DownloadButton`) already resolved via its own `playbackInfo` fetch
    /// and prompts — this doesn't re-fetch or re-prompt.
    func enqueue(
        item: MediaItem,
        mediaSource: MediaSourceInfo,
        audioTrack: MediaStream?,
        subtitleTracks: [MediaStream],
        resolution: DownloadResolution,
        preset: DownloadBitratePreset,
        client: JellyfinAPIClient,
        userID: String
    ) async throws {
        // AUDIO SUPPRESSION: `DownloadButton` only appears inside
        // `MovieDetailView`, which `AssetDetailView` already keeps an audio
        // item from rendering — so this is currently unreachable, kept as a
        // cheap first-line guard against a future bulk-/library-level
        // download entry point reaching `enqueue(...)` directly. Delete
        // once Dionysus Player supports downloading audio/music content.
        guard !item.isAudioContent else { throw DownloadError.audioContentNotSupported }
        guard let mediaSourceID = mediaSource.id else { throw DownloadError.missingMediaSource }
        // A redownload of an item that already has a row must start from a
        // clean slate rather than relying on SwiftData's unique-key merge
        // to reconcile a new `DownloadedItem` against what's already
        // persisted — an implicit partial merge risked split-brain state
        // (stored metadata showing the new quality while the on-disk video
        // was still the old one). `delete(itemID:)` already tears an
        // existing row/its files down cleanly, so reuse it here. Note: a
        // row with an unsynced `pendingSync` write survives
        // `delete(itemID:)` as `markedForDeletion`, so this isn't airtight
        // against a redownload landing in that narrow window — a known,
        // rare edge case.
        if store.item(itemID: item.id) != nil {
            delete(itemID: item.id)
        }
        let streams = mediaSource.mediaStreams ?? []
        let videoStream = streams.first { $0.type == "Video" }
        let isSourceHDR = Self.isHDR(videoStream)
        // The video track's *own* bitrate, not `mediaSource.bitrate` — that
        // one is the whole container (video + every audio and subtitle
        // track), and feeding it to a video-only cap made the cap too
        // generous by however much the audio tracks weighed, which on a
        // source with a couple of lossless surround tracks is far from
        // negligible. Falls back to the container figure only when the
        // server didn't report a per-stream one.
        let sourceVideoBitrate = videoStream?.bitRate ?? mediaSource.bitrate
        // One per download, threaded through both the stream request itself
        // and the keep-alive ping loop below — see
        // `JellyfinAPIClient.pingDownloadTranscode`'s doc comment for why a
        // download needs a real `PlaySessionId` at all.
        let playSessionId = UUID().uuidString

        guard let downloadURL = await client.downloadStreamURL(
            itemID: item.id, mediaSourceID: mediaSourceID, audioStreamIndex: audioTrack?.index,
            resolution: resolution, preset: preset, isSourceHDR: isSourceHDR,
            sourceWidth: videoStream?.width, sourceHeight: videoStream?.height,
            sourceBitrate: sourceVideoBitrate, sourceVideoCodec: videoStream?.codec,
            playSessionId: playSessionId
        ) else { throw DownloadError.invalidDownloadURL }

        let target = DownloadTranscodeCalculator.target(
            resolution: resolution, preset: preset, isSourceHDR: isSourceHDR,
            sourceWidth: videoStream?.width, sourceHeight: videoStream?.height,
            sourceBitrate: sourceVideoBitrate, sourceVideoCodec: videoStream?.codec,
            videoBitrateLadder: DownloadQualityLadderStore().videoBitrate(resolution:preset:)
        )

        let metadata = DownloadedItemMetadata(
            overview: item.dto.overview,
            taglines: (item.dto.taglines ?? []).filter { !$0.isEmpty },
            genres: item.dto.genres ?? [],
            studios: item.dto.studios?.map(\.name) ?? [],
            productionYear: item.dto.productionYear,
            premiereDate: item.dto.premiereDate,
            communityRating: item.dto.communityRating,
            officialRating: item.dto.officialRating,
            people: (item.dto.people ?? []).map { DownloadedPerson(name: $0.name, role: ($0.role?.isEmpty ?? true) ? $0.type : $0.role) }
        )

        let downloaded = DownloadedItem(
            itemID: item.id,
            userID: userID,
            mediaSourceID: mediaSourceID,
            kind: item.kind == .episode ? .episode : .movie,
            title: item.name,
            seriesID: item.dto.seriesId,
            seriesTitle: item.dto.seriesName,
            seasonID: item.dto.seasonId,
            seasonNumber: item.dto.parentIndexNumber,
            episodeNumber: item.dto.indexNumber,
            episodeLabel: item.episodeLabel,
            runtimeTicks: item.dto.runTimeTicks,
            requestedResolution: resolution,
            requestedPreset: preset,
            videoCodec: "hevc",
            audioCodec: "aac",
            width: target.maxWidth,
            height: target.maxHeight,
            bitrate: target.videoBitrate,
            // NOT `isSourceHDR` — permanently `false`, not a placeholder.
            // A download always requests a transcode (resolution/bitrate
            // capping), and Jellyfin's transcoder doesn't support HDR-to-HDR
            // output at all: any source that needs re-encoding is
            // tone-mapped to SDR unconditionally, regardless of profile or
            // `DeviceProfile` negotiation params (confirmed in Jellyfin's
            // own docs). The only way to actually preserve HDR would be a
            // stream-copy download path with no resolution/bitrate cap — a
            // distinct, larger feature, not attempted here.
            isHDR: false,
            selectedAudioTrackIndex: audioTrack?.index,
            selectedAudioTrackTitle: audioTrack?.displayTitle,
            videoFilePath: DownloadFileStore.videoRelativePath(itemID: item.id),
            skippedSubtitleTracks: subtitleTracks
                .filter { JellyfinAPIClient.isImageBasedSubtitleCodec($0.codec) }
                .map { $0.displayTitle ?? String(localized: "Track \($0.index + 1)") },
            // Not yet `.downloading` — the video task only starts once
            // `queueVideoDownload` below admits it past
            // `DownloadPreferencesStore.maxConcurrentDownloads`, which may
            // not happen right away. `pendingDownloadURLString` lets that
            // later admission (even after a relaunch) find its way back to
            // this URL.
            status: .queued,
            pendingDownloadURLString: downloadURL.absoluteString,
            metadata: metadata
        )
        // Inserted before the artwork/segments/trickplay fetches below, not
        // after — a slow "cold" Jellyfin server can take several seconds on
        // those, and without a row to key off, `DownloadButton`/
        // `SeasonDownloadButton`'s `isPreparing` state had nothing to show.
        // Backfilled in place once the fetches below resolve.
        store.insert(downloaded)

        let images = await client.makeImageURLBuilder()
        // Poster/backdrop/logo/thumb/segments/trickplay are all mutually
        // independent — fetched concurrently rather than one after another,
        // so the actual video transfer isn't needlessly delayed.
        async let posterPathTask = downloadImageIfNeeded(sourceItemID: item.id, imageType: "Primary", tag: item.dto.imageTags?["Primary"], maxWidth: 500, images: images)
        // Backdrop/logo: own image if present, else the nearest ancestor's
        // (same fallback `MediaItem.backdropImageURL`/`logoImageURL` apply
        // live) — see `resolveBackdropPath`/`resolveLogoPath` below.
        async let backdropPathTask = resolveBackdropPath(for: item, images: images)
        async let logoPathTask = resolveLogoPath(for: item, images: images)
        async let thumbPathTask = downloadImageIfNeeded(sourceItemID: item.id, imageType: "Thumb", tag: item.dto.imageTags?["Thumb"], maxWidth: 500, images: images)
        async let segmentDTOsTask = (try? await client.mediaSegments(itemID: item.id)) ?? []
        async let trickplayInfoTask = downloadTrickplayTiles(itemID: item.id, mediaSourceID: mediaSourceID, client: client, userID: userID, images: images)
        // `item.chapters` is already populated — `JellyfinAPIClient
        // .detailFields` carries `Chapters`, so every DTO that reaches this
        // method has them, with no extra fetch of its own the way trickplay
        // needs one.
        async let chaptersTask = downloadChapterImages(itemID: item.id, chapters: item.chapters, images: images)

        let (posterPath, backdropPath, logoPath, thumbPath, segmentDTOs, trickplayInfo, chapters) = await (
            posterPathTask, backdropPathTask, logoPathTask, thumbPathTask, segmentDTOsTask, trickplayInfoTask, chaptersTask
        )

        downloaded.posterImagePath = posterPath
        downloaded.backdropImagePath = backdropPath
        downloaded.logoImagePath = logoPath
        downloaded.thumbImagePath = thumbPath
        downloaded.segments = segmentDTOs.compactMap { dto in
            guard let kind = Self.downloadedSegmentKind(from: dto.type) else { return nil }
            return DownloadedSegment(kind: kind, startSeconds: Double(dto.startTicks) / 10_000_000, endSeconds: Double(dto.endTicks) / 10_000_000)
        }
        downloaded.chapters = chapters
        downloaded.trickplayInfo = trickplayInfo
        downloaded.subtitleFiles = await downloadSubtitles(
            itemID: item.id, mediaSourceID: mediaSourceID, tracks: subtitleTracks, client: client
        )
        store.save()

        // Staged rather than started here — see `pendingPollStarters`. The
        // loop begins the moment `queueVideoDownload` admits this item past
        // the concurrency limit, which for the first item is the very next
        // line and for anything behind it is whenever a slot frees.
        pendingPollStarters[item.id] = { [weak self] in
            // Started for every download, not just a real re-encode — the
            // keep-alive ping this loop also sends matters for a stream-copy
            // job too (still a `Progressive`-type job on the server, subject
            // to the same kill-timer). `videoStreamCopyEligible` only affects
            // whether a completion percentage ever shows up to read, which
            // `startTranscodeProgressPolling` already handles by simply
            // finding nothing to apply.
            self?.startTranscodeProgressPolling(itemID: item.id, playSessionId: playSessionId, client: client)
        }
        queueVideoDownload(itemID: item.id)
    }

    /// Re-attempts a `.failed` download using the same resolution/quality/
    /// audio-track choice as the original attempt — no re-prompting, since
    /// those were already explicit user choices. Needs a live `client`;
    /// callers should hide/disable this when there isn't one (the offline
    /// Downloads pages this is called from are usable with no session at
    /// all). A no-op if the row isn't actually `.failed`.
    func retry(itemID: String, client: JellyfinAPIClient) async throws {
        guard let row = store.item(itemID: itemID), row.status == .failed else { return }
        let images = await client.makeImageURLBuilder()
        guard let dto = try? await client.item(userID: row.userID, itemID: itemID, fields: JellyfinAPIClient.detailFieldsWithTrickplay) else {
            throw DownloadError.itemNoLongerAvailable
        }
        let item = MediaItem(dto: dto, images: images)

        let info = try await client.playbackInfo(itemID: itemID, userID: row.userID, mediaSourceID: row.mediaSourceID)
        guard let mediaSource = info.mediaSources?.first(where: { $0.id == row.mediaSourceID }) ?? info.mediaSources?.first else {
            throw DownloadError.missingMediaSource
        }
        let streams = mediaSource.mediaStreams ?? []
        let audioTracks = streams.filter { $0.type == "Audio" }
        // Same track index the user originally picked, if it's still
        // present in this fresh negotiation; falls back the same way a
        // first-time download with no explicit choice would (default,
        // else first) rather than failing the retry outright over a track
        // list that shuffled slightly server-side.
        let audioTrack = audioTracks.first { $0.index == row.selectedAudioTrackIndex }
            ?? audioTracks.first { $0.isDefault == true }
            ?? audioTracks.first
        let subtitleTracks = streams.filter { $0.type == "Subtitle" }

        try await enqueue(
            item: item, mediaSource: mediaSource, audioTrack: audioTrack, subtitleTracks: subtitleTracks,
            resolution: row.requestedResolution, preset: row.requestedPreset,
            client: client, userID: row.userID
        )
    }

    /// Downloads every text-based subtitle track inline via a plain shared
    /// session (small, quick — unlike the video, these don't need a
    /// background task). Image-based tracks were already excluded before
    /// this is called (recorded as `skippedSubtitleTracks` instead) — see
    /// `JellyfinAPIClient.isImageBasedSubtitleCodec`. A single track's
    /// fetch failing is non-fatal: it's just dropped rather than failing
    /// the whole download, since the video is the part that matters most.
    private func downloadSubtitles(
        itemID: String, mediaSourceID: String, tracks: [MediaStream], client: JellyfinAPIClient
    ) async -> [DownloadedSubtitleFile] {
        var files: [DownloadedSubtitleFile] = []
        let session = adHocFetchSession
        for stream in tracks where !JellyfinAPIClient.isImageBasedSubtitleCodec(stream.codec) {
            guard let url = await client.subtitleURL(itemID: itemID, mediaSourceID: mediaSourceID, streamIndex: stream.index, codec: stream.codec) else { continue }
            do {
                let (data, _) = try await session.data(for: makeFetchRequest(url: url))
                let ext = JellyfinAPIClient.subtitleFileExtension(forCodec: stream.codec)
                let relativePath = DownloadFileStore.subtitleRelativePath(itemID: itemID, index: stream.index, language: stream.language, fileExtension: ext)
                try DownloadFileStore.write(data, toRelativePath: relativePath)
                files.append(DownloadedSubtitleFile(
                    index: stream.index,
                    language: stream.language,
                    displayTitle: stream.displayTitle ?? String(localized: "Track \(stream.index + 1)"),
                    isForced: stream.isForced ?? false,
                    isDefault: stream.isDefault ?? false,
                    isHearingImpaired: stream.isHearingImpaired ?? false,
                    relativePath: relativePath
                ))
            } catch {
                continue
            }
        }
        return files
    }

    /// The fetch-time half of the shared-artwork dedup (see
    /// `DownloadFileStore`'s doc comment): reuses an already-downloaded
    /// file for this exact `(sourceItemID, imageType, tag)` identity
    /// instead of re-fetching. A missing `tag` does **not** mean "skip this
    /// image" — an episode routinely has no `imageTags["Primary"]` entry at
    /// all, yet its live image route still serves a real still frame — so a
    /// `nil` tag falls back to a fixed `"untagged"` placeholder identity
    /// instead of skipping the fetch. Checks the HTTP status explicitly,
    /// since `URLSession.data(from:)` doesn't throw on a 404 — an item with
    /// nothing at this route would otherwise silently write an error body
    /// to disk as if it were image data.
    private func downloadImageIfNeeded(sourceItemID: String, imageType: String, tag: String?, maxWidth: Int, images: ImageURLBuilder) async -> String? {
        let identityTag = tag ?? "untagged"
        let relativePath = DownloadFileStore.imageRelativePath(sourceItemID: sourceItemID, imageType: imageType, tag: identityTag)
        if DownloadFileStore.imageAlreadyExists(sourceItemID: sourceItemID, imageType: imageType, tag: identityTag) {
            return relativePath
        }
        guard let url = images.url(itemID: sourceItemID, imageType: imageType, tag: tag, maxWidth: maxWidth) else { return nil }
        do {
            let (data, response) = try await adHocFetchSession.data(for: makeFetchRequest(url: url))
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else { return nil }
            try DownloadFileStore.write(data, toRelativePath: relativePath)
            return relativePath
        } catch {
            return nil
        }
    }

    /// `enqueue`'s backdrop resolution, split out into its own function
    /// (rather than inlined `if`/`else if` statements) so it can be started
    /// as one independent `async let` task alongside `enqueue`'s other
    /// metadata/artwork fetches — own image if present, else the nearest
    /// ancestor's (same fallback `MediaItem.backdropImageURL` applies live).
    private func resolveBackdropPath(for item: MediaItem, images: ImageURLBuilder) async -> String? {
        if let tag = item.dto.backdropImageTags?.first {
            return await downloadImageIfNeeded(sourceItemID: item.id, imageType: "Backdrop", tag: tag, maxWidth: 1600, images: images)
        } else if let parentID = item.dto.parentBackdropItemId, let tag = item.dto.parentBackdropImageTags?.first {
            return await downloadImageIfNeeded(sourceItemID: parentID, imageType: "Backdrop", tag: tag, maxWidth: 1600, images: images)
        }
        return nil
    }

    /// Same shape as `resolveBackdropPath`, for the logo fallback
    /// (`MediaItem.logoImageURL`'s own live equivalent).
    private func resolveLogoPath(for item: MediaItem, images: ImageURLBuilder) async -> String? {
        if let tag = item.dto.imageTags?["Logo"] {
            return await downloadImageIfNeeded(sourceItemID: item.id, imageType: "Logo", tag: tag, maxWidth: 600, images: images)
        } else if let parentID = item.dto.parentLogoItemId, let tag = item.dto.parentLogoImageTag {
            return await downloadImageIfNeeded(sourceItemID: parentID, imageType: "Logo", tag: tag, maxWidth: 600, images: images)
        }
        return nil
    }

    /// Fetches this item's trickplay track (if scanned) and every
    /// tile-sheet JPEG, so `OfflineTrickplayThumbnailProvider` has
    /// something to read while scrubbing offline — the offline counterpart
    /// to `TrickplayThumbnailProvider`'s live on-demand fetch. Re-fetches
    /// the item with `JellyfinAPIClient.detailFieldsWithTrickplay`
    /// explicitly, since the caller's own DTO doesn't carry `Trickplay`.
    /// Entirely best-effort: returns `nil` if there's no track or the fetch
    /// to learn that fails; once a track is found, a single sheet failing
    /// is non-fatal.
    private func downloadTrickplayTiles(
        itemID: String, mediaSourceID: String, client: JellyfinAPIClient, userID: String, images: ImageURLBuilder
    ) async -> TrickplayInfo? {
        guard let dto = try? await client.item(userID: userID, itemID: itemID, fields: JellyfinAPIClient.detailFieldsWithTrickplay),
              let info = TrickplayMath.bestInfo(from: dto.trickplay, mediaSourceID: mediaSourceID)
        else { return nil }

        let sheetCount = TrickplayMath.sheetCount(for: info)
        guard sheetCount > 0 else { return nil }
        // Computed once, on this method's own actor context, and captured
        // by value below — `URLSession` is `Sendable`, so this avoids any
        // of `group.addTask`'s child-task closures needing to cross back
        // to `self`'s actor isolation just to read `adHocFetchSession`.
        let session = adHocFetchSession
        // Read here and captured by value for the same reason `session` is —
        // see `makeFetchRequest(url:allowsCellularAccess:)`.
        let allowsCellularAccess = !preferences.wifiOnly
        // Concurrent, bounded to `maxConcurrentTrickplaySheetDownloads` —
        // every sheet index is independent, so there's no reason to await
        // each one's full round-trip before starting the next.
        await withTaskGroup(of: Void.self) { group in
            for sheetIndex in 0..<sheetCount {
                if sheetIndex >= Self.maxConcurrentTrickplaySheetDownloads {
                    _ = await group.next()
                }
                group.addTask {
                    guard let url = images.trickplayTileURL(itemID: itemID, width: info.width, sheetIndex: sheetIndex) else { return }
                    do {
                        let (data, response) = try await session.data(for: Self.makeFetchRequest(url: url, allowsCellularAccess: allowsCellularAccess))
                        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else { return }
                        let relativePath = DownloadFileStore.trickplayTileRelativePath(itemID: itemID, width: info.width, sheetIndex: sheetIndex)
                        try DownloadFileStore.write(data, toRelativePath: relativePath)
                    } catch {
                        return
                    }
                }
            }
            await group.waitForAll()
        }
        return info
    }

    /// Captures this item's chapter markers, fetching each chapter's still
    /// frame into the shared, content-addressed image pool so the offline
    /// detail page's Chapters rail and the player's chapter picker have
    /// artwork with no network — the chapter counterpart to
    /// `downloadTrickplayTiles`, and shaped the same way.
    ///
    /// Entirely best-effort per chapter: a failed (or absent) image just
    /// leaves that entry's `imageRelativePath` `nil`, which renders as
    /// `MediaPlaceholderBox` rather than failing the download. A chapter
    /// with no `imageTag` is never even attempted — that's Jellyfin's
    /// definitive "no image here" signal (see `ChapterInfoDto.imageTag`),
    /// unlike the tagless-but-still-served Primary images
    /// `downloadImageIfNeeded` deliberately allows for.
    ///
    /// Takes the already-mapped `[Chapter]` rather than the raw DTOs so the
    /// "a single dummy chapter means no chapters" rule stays in exactly one
    /// place (`MediaItem.chapters`).
    ///
    /// Concurrent and bounded to `maxConcurrentTrickplaySheetDownloads`, the
    /// same shape (and for the same reason) `downloadTrickplayTiles` uses:
    /// a feature film can carry 30+ chapters, and this whole batch is
    /// awaited *before* `queueVideoDownload` starts the actual transfer, so
    /// fetching them one round trip at a time would visibly delay the start
    /// of every download against a slow server. Results are re-sorted by
    /// chapter index afterwards — a task group completes in whatever order
    /// the network happens to finish in, and the stored list has to stay in
    /// timeline order.
    private func downloadChapterImages(itemID: String, chapters: [Chapter], images: ImageURLBuilder) async -> [DownloadedChapter] {
        // Read once here and captured by value below — same reasoning
        // `downloadTrickplayTiles` spells out: `URLSession` is `Sendable`,
        // so hoisting it lets each child task run fully `nonisolated`
        // instead of hopping back to this `@MainActor` type just to read
        // it. Worth more here than it looks: without it, each chapter's
        // ~100KB `DownloadFileStore.write` would be a synchronous disk
        // write on the main thread, 30+ times over for a feature film.
        let session = adHocFetchSession
        let allowsCellularAccess = !preferences.wifiOnly
        var stored: [DownloadedChapter] = []
        await withTaskGroup(of: DownloadedChapter.self) { group in
            for (offset, chapter) in chapters.enumerated() {
                if offset >= Self.maxConcurrentTrickplaySheetDownloads, let finished = await group.next() {
                    stored.append(finished)
                }
                group.addTask {
                    var relativePath: String?
                    if let tag = chapter.imageTag {
                        relativePath = await Self.downloadChapterImage(
                            itemID: itemID, chapterIndex: chapter.index, tag: tag, images: images,
                            session: session, allowsCellularAccess: allowsCellularAccess
                        )
                    }
                    return DownloadedChapter(
                        index: chapter.index,
                        name: chapter.name,
                        startSeconds: chapter.startSeconds,
                        imageRelativePath: relativePath
                    )
                }
            }
            for await finished in group {
                stored.append(finished)
            }
        }
        return stored.sorted { $0.index < $1.index }
    }

    /// One chapter still, stored under the same content-addressed
    /// `(sourceItemID, imageType, tag)` identity every other downloaded
    /// image uses — with the chapter *index* folded into the type segment
    /// (`"Chapter0"`, `"Chapter1"`, …), since a single item's chapters can
    /// and do share one `imageTag` value, which a plain `"Chapter"` type
    /// would collapse into a single file. Not a call to
    /// `downloadImageIfNeeded` for the same reason: this route needs the
    /// index in its *URL* too, which that helper's `url(itemID:imageType:…)`
    /// can't build.
    ///
    /// `nonisolated static`, taking its `session` as a parameter, so
    /// `downloadChapterImages`' task group can call it without hopping back
    /// to this `@MainActor` type — see that method's own comment.
    private nonisolated static func downloadChapterImage(
        itemID: String, chapterIndex: Int, tag: String, images: ImageURLBuilder,
        session: URLSession, allowsCellularAccess: Bool
    ) async -> String? {
        let imageType = "Chapter\(chapterIndex)"
        let relativePath = DownloadFileStore.imageRelativePath(sourceItemID: itemID, imageType: imageType, tag: tag)
        if DownloadFileStore.imageAlreadyExists(sourceItemID: itemID, imageType: imageType, tag: tag) {
            return relativePath
        }
        guard let url = images.chapterImageURL(itemID: itemID, chapterIndex: chapterIndex, tag: tag, maxWidth: 640) else { return nil }
        do {
            let (data, response) = try await session.data(for: Self.makeFetchRequest(url: url, allowsCellularAccess: allowsCellularAccess))
            // An unexpected 404 here is a normal outcome, not an error worth
            // surfacing — an older/unpatched server can report a phantom tag
            // for a chapter it has no image for. Same explicit status check
            // `downloadImageIfNeeded` makes, and for the same reason:
            // `URLSession.data(from:)` doesn't throw on a 404.
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else { return nil }
            try DownloadFileStore.write(data, toRelativePath: relativePath)
            return relativePath
        } catch {
            return nil
        }
    }

    /// `error.localizedDescription` alone surfaces a raw system string for
    /// the most common real-world failure: force-quitting the app cancels
    /// its background transfers by design (distinct from the OS suspending
    /// or killing a backgrounded app under memory pressure, which
    /// `adoptInFlightDownloads` recovers from) — `NSURLErrorCancelled`
    /// (-999) on reattachment reflects that real cancellation, not a bug,
    /// but still deserves a friendlier message than the raw error code.
    ///
    /// The background-session cases below are only ever reached once
    /// `resolveFailedDownload` has already spent the automatic retry budget,
    /// so the wording says "after several attempts" rather than implying a
    /// single hiccup. Before this, `error.localizedDescription` surfaced
    /// iOS's own "Lost connection to the background transfer service"
    /// verbatim — the exact string users were reporting, and one that reads
    /// as an app defect while naming a system component nobody outside the
    /// OS knows about.
    /// Not `private` — `DownloadManagerTests` asserts the -997 row no longer
    /// carries the raw system string, which is the literal regression test
    /// for the reported bug.
    static func friendlyDownloadFailureMessage(for error: Error) -> String {
        guard let urlError = error as? URLError else { return error.localizedDescription }
        switch urlError.code {
        case .cancelled:
            return String(localized: "The download was interrupted and couldn't continue. Try downloading again.")
        case .backgroundSessionWasDisconnected, .backgroundSessionInUseByAnotherProcess:
            return String(localized: "iOS interrupted this download several times and it couldn't be completed. Try downloading again.")
        case .networkConnectionLost, .timedOut, .cannotConnectToHost:
            return String(localized: "The connection to the server kept dropping and the download couldn't finish. Check your network and try again.")
        default:
            return error.localizedDescription
        }
    }

    /// Not `private` — `DownloadButton`'s Advanced Options size estimate
    /// needs the identical classification against a source it hasn't
    /// downloaded yet, and duplicating this four-line check would be the
    /// kind of drift-prone copy this codebase otherwise avoids.
    static func isHDR(_ videoStream: MediaStream?) -> Bool {
        guard let type = videoStream?.videoRangeType ?? videoStream?.videoRange else { return false }
        return type.hasPrefix("DOVI") || type == "HDR10" || type == "HDR10Plus" || type == "HLG"
    }

    private static func downloadedSegmentKind(from type: MediaSegmentType) -> DownloadedSegment.Kind? {
        switch type {
        case .intro: return .intro
        case .outro: return .outro
        case .recap: return .recap
        case .preview: return .preview
        case .commercial: return .commercial
        case .unknown: return nil
        }
    }

    // MARK: - Concurrency-limited queue

    /// Appends to `pendingQueue` (no-op if already there) and immediately
    /// tries to admit it. Not `private` — `DownloadManagerTests` also calls
    /// this directly to drive the queue without the full async `enqueue`.
    func queueVideoDownload(itemID: String) {
        guard !pendingQueue.contains(itemID) else { return }
        pendingQueue.append(itemID)
        admitQueuedDownloadsIfPossible()
    }

    /// Starts as many queued video downloads as
    /// `DownloadPreferencesStore.maxConcurrentDownloads` currently allows,
    /// strictly in FIFO order — called whenever the queue gains an entry or
    /// a slot frees up. A popped row that's no longer actually `.queued`
    /// with a URL to start is silently skipped.
    private func admitQueuedDownloadsIfPossible() {
        // Saved once, after the loop — not once per admitted row, so
        // several slots freeing up at once doesn't mean several SwiftData
        // round-trips.
        var admittedAny = false
        while canStartAnotherDownload {
            guard !pendingQueue.isEmpty else { break }
            let itemID = pendingQueue.removeFirst()
            guard let row = store.item(itemID: itemID), row.status == .queued,
                  let urlString = row.pendingDownloadURLString, let url = URL(string: urlString)
            else { continue }
            row.status = .downloading
            // Deliberately *not* cleared here any more. It is this row's
            // download URL for as long as the row is downloading, which is
            // what lets `resolveFailedDownload` re-arm a transfer after a
            // transient transport failure without re-running any of
            // `enqueue`'s artwork/subtitle/trickplay/chapter prep. Both
            // readers already gate on `status == .queued`, so nothing else
            // changes.
            admittedAny = true
            // Reserve the slot before either starter below runs, so a
            // `startVideoDownloadOverride` (tests only) that does nothing
            // still counts against the limit without having to reach into
            // this type's private state itself.
            activeItemIDs.insert(itemID)
            if let startVideoDownloadOverride {
                startVideoDownloadOverride(itemID, url, row.videoFilePath)
            } else {
                startVideoDownload(itemID: itemID, url: url, relativePath: row.videoFilePath)
            }
            // Only now that a real transfer exists is there a server-side
            // transcode job for the loop to ping and read — see
            // `pendingPollStarters`. Absent for a row resumed after a
            // relaunch (no client that early), which is the documented gap.
            pendingPollStarters.removeValue(forKey: itemID)?()
        }
        if admittedAny { store.save() }
    }

    /// `activeItemIDs.count` is exactly "how many video downloads are
    /// actually transferring right now" (see that property's own doc
    /// comment) — `nil` (Unlimited) always allows another.
    private var canStartAnotherDownload: Bool {
        guard let limit = preferences.maxConcurrentDownloads else { return true }
        return activeItemIDs.count < limit
    }

    /// Rebuilds `pendingQueue` from `.queued` rows that survived to a fresh
    /// launch — unlike an already-started download (which reattaches via
    /// its background `URLSession`), a merely-queued row has no in-memory
    /// queue entry to resume from otherwise. Ordered by `createdAt` so a
    /// relaunch preserves tap order. Called from `init` **after**
    /// `adoptInFlightDownloads` — see that method's doc comment for why
    /// the order matters.
    private func resumePendingQueue() {
        let queuedRows = store.allItems()
            .filter { $0.status == .queued && $0.pendingDownloadURLString != nil }
            .sorted { $0.createdAt < $1.createdAt }
        pendingQueue = queuedRows.map(\.itemID)
        admitQueuedDownloadsIfPossible()
    }

    /// Re-adopts every row still `.downloading` at launch, against the one
    /// background session's live task list.
    ///
    /// Needed because `handleBackgroundSessionEvents` only runs when the OS
    /// relaunches the app specifically to deliver a finished background
    /// session's events — an ordinary relaunch (force-quit + reopen, or a
    /// jetsam kill followed by a plain tap) never goes through it, so
    /// without this a `.downloading` row surviving either would sit stuck at
    /// "Downloading…" forever.
    ///
    /// The slot is reserved **synchronously**, before the async sweep
    /// returns. Under the old session-per-item scheme it couldn't be: a
    /// stale `.downloading` row would then have jammed a concurrency slot
    /// forever, because nothing could cheaply tell a live identifier from a
    /// dead one, so reservation waited on a per-item liveness check and
    /// `resumePendingQueue()` could transiently admit one row past the
    /// limit. With one session, `finishAdopting` resolves *every* stale row
    /// in a single pass, so reserving up front is now both safe and exact —
    /// and the whole `reattachmentPending` race (two sessions racing to
    /// claim one identifier) ceases to exist along with the second session.
    private func adoptInFlightDownloads() {
        let downloadingRows = store.allItems().filter { $0.status == .downloading }
        guard !downloadingRows.isEmpty else { return }
        for row in downloadingRows {
            activeItemIDs.insert(row.itemID)
        }
        if let reattachVideoDownloadOverride {
            // Test seam: no real session to sweep, so the override stands in
            // for "every one of these is still live".
            downloadingRows.forEach { reattachVideoDownloadOverride($0.itemID) }
            return
        }
        // The reserved set is captured here and passed through, rather than
        // re-read from `activeItemIDs` when the sweep returns: `init` calls
        // `resumePendingQueue()` immediately after this, which can admit and
        // start fresh downloads *before* the async callback fires. Those
        // start after `getAllTasks` took its snapshot, so they aren't in it —
        // reconciling against the live set would resolve a download that had
        // only just begun as one whose transfer had vanished.
        let reserved = Set(downloadingRows.map(\.itemID))
        backgroundSession.getAllTasks { [weak self] tasks in
            Task { @MainActor in
                self?.finishAdopting(tasks: tasks, reserved: reserved)
            }
        }
    }

    /// Reconciles the session's real task list against the store, in one
    /// pass — see `adoptInFlightDownloads`.
    private func finishAdopting(tasks: [URLSessionTask], reserved: Set<String>) {
        var adopted: Set<String> = []
        for task in tasks {
            guard let downloadTask = task as? URLSessionDownloadTask else { continue }
            guard let itemID = adoptedItemID(for: downloadTask),
                  let row = store.item(itemID: itemID), row.status == .downloading
            else {
                // A transfer whose row is gone (deleted mid-download, or
                // deleted while the app wasn't running) — the transfer-layer
                // counterpart of `DownloadFileStore.deleteOrphanedItemDirectories`,
                // and the reason a deleted item can't go on quietly writing
                // bytes into a directory that sweep will later remove.
                task.cancel()
                continue
            }
            downloadTasks[itemID] = downloadTask
            adopted.insert(itemID)
        }
        // Whatever was reserved above but has no live task behind it: the
        // transfer died while the app wasn't running. Routed through the
        // same automatic-retry path as any other transport failure rather
        // than failed outright, since that is exactly the -997 shape.
        for itemID in reserved.subtracting(adopted) {
            activeItemIDs.remove(itemID)
            resolveFailedDownload(itemID: itemID, error: URLError(.backgroundSessionWasDisconnected))
        }
        admitQueuedDownloadsIfPossible()
    }

    /// Which row a live task belongs to. `taskDescription` is the primary
    /// route — it's set to the itemID at creation and background sessions
    /// persist it with the task across a relaunch. The URL fallback exists
    /// because that persistence is asserted by documentation and only
    /// actually confirmed on a device; it costs one pass over rows already
    /// in memory, now that `pendingDownloadURLString` survives admission.
    private func adoptedItemID(for task: URLSessionTask) -> String? {
        if let description = task.taskDescription, !description.isEmpty {
            return description
        }
        guard let urlString = task.originalRequest?.url?.absoluteString else { return nil }
        return store.allItems().first { $0.pendingDownloadURLString == urlString }?.itemID
    }

    // MARK: - Video download (background session)

    /// The one configuration behind `backgroundSession` — applies
    /// `downloadRequestTimeout`/`downloadResourceTimeout` explicitly, since
    /// a bare `.background(withIdentifier:)` configuration silently falls
    /// back to the system default (measured in days) otherwise, and
    /// `waitsForConnectivity` so a transfer started with no usable network
    /// defers rather than failing outright.
    ///
    /// Cellular is permitted at this level and gated per *request* instead
    /// (`makeFetchRequest(url:allowsCellularAccess:)`): a session that lives
    /// for the whole process can't have its configuration rewritten when the
    /// Wi-Fi Only toggle flips, whereas a request flag is re-read on every
    /// transfer. Strictly better than what it replaced, which also missed a
    /// personal hotspot entirely.
    ///
    /// Not `private` — `DownloadManagerTests` asserts on the returned
    /// configuration directly (a pure function, no real network involved),
    /// which is what pins the single-identifier property.
    static func makeBackgroundConfiguration() -> URLSessionConfiguration {
        #if DEBUG
        // A background configuration runs its transfers in a separate system
        // daemon, which is out of reach of `URLProtocol` entirely — a stub
        // registered in this process would simply never be consulted, and
        // the download would try to hit the network for real. Under a UI
        // test the session therefore drops to a default (in-process)
        // configuration so the stub can serve it.
        //
        // This is a real behavioural divergence, and the reason downloads
        // are covered here only up to "bytes land and the row settles":
        // backgrounding, suspension and OS-relaunch resumption are exactly
        // what a default configuration does not reproduce. Those stay
        // device-only manual checks, as `TESTING.md` already records.
        if UITestConfiguration.isActive {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = downloadRequestTimeout
            configuration.timeoutIntervalForResource = downloadResourceTimeout
            configuration.allowsCellularAccess = true
            UITestHarness.decorate(configuration)
            return configuration
        }
        #endif
        let configuration = URLSessionConfiguration.background(withIdentifier: backgroundSessionIdentifier)
        configuration.timeoutIntervalForRequest = downloadRequestTimeout
        configuration.timeoutIntervalForResource = downloadResourceTimeout
        configuration.allowsCellularAccess = true
        configuration.waitsForConnectivity = true
        return configuration
    }

    /// Starts one transfer on the shared session. `taskDescription` carries
    /// the itemID — it is how `DownloadTaskRouter` routes every callback
    /// back to a row, including after an OS relaunch, so it must be set
    /// before `resume()`.
    private func startVideoDownload(itemID: String, url: URL, relativePath: String) {
        let task = backgroundSession.downloadTask(
            with: Self.makeFetchRequest(url: url, allowsCellularAccess: !preferences.wifiOnly)
        )
        task.taskDescription = itemID
        downloadTasks[itemID] = task
        task.resume()
    }

    /// Re-attaches the app's background session so the OS can finish
    /// delivering callbacks for transfers that completed while the app was
    /// suspended or terminated, then answers the completion handler UIKit
    /// handed us. Called from `AppDelegate.application(_:
    /// handleEventsForBackgroundURLSession:completionHandler:)` via
    /// `NotificationCenter` (see `init`).
    ///
    /// Answering the handler is not optional: the OS treats an unanswered
    /// one as "this app is still busy" and reclaims its background time
    /// more aggressively next time. The session-per-item scheme had three
    /// separate paths on which a stashed handler was silently never called
    /// (a `finishTasksAndInvalidate()` beating `urlSessionDidFinishEvents`,
    /// a reattach that found no live task and invalidated, and a stash for
    /// an itemID that already had a delegate). With one session and no
    /// invalidation at all, the only remaining hole is "events had already
    /// been delivered before we stashed" — closed by the empty-task-list
    /// check and the timed backstop below.
    private func handleBackgroundSessionEvents(identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == Self.backgroundSessionIdentifier else {
            // A session identifier from the previous, per-item scheme. There
            // is nothing left in this app to route its callbacks to, but the
            // handler still has to be answered, and the session itself
            // reclaimed. See `legacyPerItemSessionIdentifierPrefix`.
            if identifier.hasPrefix(Self.legacyPerItemSessionIdentifierPrefix) {
                // The router is handed over rather than `nil` because a
                // background configuration is documented as requiring a
                // delegate; it ignores these tasks anyway, since a legacy
                // task carries no `taskDescription` to route by.
                URLSession(configuration: .background(withIdentifier: identifier), delegate: router, delegateQueue: nil)
                    .invalidateAndCancel()
            }
            completionHandler()
            return
        }
        // Answer any previous handler before replacing it, rather than
        // dropping it — see this method's own doc comment.
        backgroundCompletionHandler?()
        backgroundCompletionHandler = completionHandler
        // Touching the session is what actually re-attaches it and starts
        // the queued callbacks flowing.
        backgroundSession.getAllTasks { [weak self] tasks in
            Task { @MainActor in
                guard let self else { return }
                // Nothing left in flight means every event was delivered
                // before this handler was stashed, so
                // `urlSessionDidFinishEvents` will never arrive to answer it.
                if tasks.isEmpty { self.answerBackgroundCompletionHandler() }
            }
        }
        // Hard backstop, well inside the ~30s the OS allows: better to
        // answer slightly early than to leave it unanswered on some path
        // nobody anticipated.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(25))
            self?.answerBackgroundCompletionHandler()
        }
    }

    /// Idempotent — every caller races the others by design.
    private func answerBackgroundCompletionHandler() {
        guard let handler = backgroundCompletionHandler else { return }
        backgroundCompletionHandler = nil
        handler()
    }

    /// Reclaims the background sessions left live in `nsurlsessiond` by a
    /// build that predates the single-session change: those still hold real
    /// tasks whose callbacks now have nothing in this app to route to, and
    /// nothing would ever free them otherwise. Runs once, ever.
    ///
    /// Scoped to `.downloading` rows only, and deliberately so: creating a
    /// background session is an XPC round trip, this runs on the main actor
    /// during `init`, and sweeping a whole library's worth of rows would be
    /// exactly the launch-time session churn this change exists to remove.
    /// Any other status had its session invalidated by the old code's own
    /// completion path already. Each row it does touch is then resolved by
    /// `finishAdopting` in the same launch. Delete this (and
    /// `legacyPerItemSessionIdentifierPrefix`) once a couple of releases
    /// have shipped — by then no device can still be carrying one.
    private func sweepLegacyPerItemSessions() {
        let key = "downloadsLegacyPerItemSessionSweepCompleted"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        for row in store.allItems() where row.status == .downloading {
            let identifier = Self.legacyPerItemSessionIdentifierPrefix + row.itemID
            URLSession(configuration: .background(withIdentifier: identifier), delegate: router, delegateQueue: nil)
                .invalidateAndCancel()
        }
    }

    private func handleDownloadProgress(itemID: String, downloaded: Int64, expected: Int64) {
        // Re-queried per tick rather than captured, now that one router
        // serves every download — a dictionary lookup against an in-memory
        // SwiftData row, not a fetch.
        let estimatedTotalBytes = store.item(itemID: itemID)?.estimatedTotalBytes ?? 0
        let total = expected > 0 ? expected : estimatedTotalBytes
        // Merged into whatever's already there, not overwritten — a fresh
        // `DownloadProgress()` here would blow away
        // `transcodeCompletionPercentage` set by the independent polling loop
        // (`startTranscodeProgressPolling`) every time a new byte chunk
        // arrives.
        var progress = activeDownloads[itemID] ?? DownloadProgress(bytesDownloaded: 0, totalBytesExpected: 0)
        progress.bytesDownloaded = downloaded
        progress.totalBytesExpected = total
        activeDownloads[itemID] = progress
    }

    private func handleDownloadCompletion(itemID: String, result: Result<Void, Error>) {
        // One line doing three jobs. `didFinishDownloadingTo` and
        // `didCompleteWithError` are not mutually exclusive at the
        // `URLSession` level — a task can deliver its file and *then*
        // complete with an error — and because the failure report lands
        // second it used to win the row's status write, flipping a genuinely
        // `.completed` download to `.failed`, while freeing the concurrency
        // slot twice and letting the queue admit one row past its limit.
        // It also drops any callback for an item the user deleted
        // mid-transfer, since `delete(itemID:)` removes the id here too.
        // `DownloadTaskRouter` carries an independent guard of its own; they
        // fail in different directions, and this symptom would masquerade
        // convincingly as "the -997 fix didn't work".
        guard activeItemIDs.remove(itemID) != nil else { return }
        activeDownloads[itemID] = nil
        downloadTasks[itemID] = nil
        // A slot just freed up — try to admit whatever's next in line
        // regardless of whether this row still exists below (it may have
        // been deleted mid-download). No session teardown here any more:
        // `backgroundSession` outlives every individual transfer, which is
        // the whole point of the single-session design.
        admitQueuedDownloadsIfPossible()
        switch result {
        case .success:
            stopTranscodeProgressPolling(itemID: itemID)
            automaticRetryAttempts[itemID] = nil
            // Split into its own `Task` — validating needs to `await` an
            // `AVURLAsset` duration load, which the caller (a synchronous
            // callback) can't do directly. The queue cleanup above already
            // ran unconditionally, so freeing this concurrency slot for the
            // next queued download doesn't wait on it.
            let relativePath = DownloadFileStore.videoRelativePath(itemID: itemID)
            Task { @MainActor in
                await self.finalizeCompletedDownload(itemID: itemID, relativePath: relativePath)
            }
        case .failure(let error):
            resolveFailedDownload(itemID: itemID, error: error)
        }
    }

    // MARK: - Transient transport failures

    /// Whether a transfer died for a reason that says nothing about whether
    /// the download can ultimately succeed — in which case re-arming it is
    /// far better than showing the user a failed row.
    ///
    /// `.backgroundSessionWasDisconnected` (-997) is the one this exists
    /// for: the app's channel to `nsurlsessiond` went away, which is a fact
    /// about the daemon and not about the download. `.cancelled` (-999) is
    /// deliberately *not* here — that is a real user force-quit or an OS
    /// cancellation, and silently restarting a transcode the user may not
    /// still want would be worse than reporting it. Nor is
    /// `DownloadTransferError.badStatus`: the server answered, and said no.
    /// Anything unrecognised stays a visible failure rather than a silent
    /// loop.
    static func isRetryableTransportError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .backgroundSessionWasDisconnected, .backgroundSessionInUseByAnotherProcess,
             .networkConnectionLost, .timedOut, .cannotConnectToHost:
            return true
        default:
            return false
        }
    }

    /// Either re-arms the transfer (transport failure, budget remaining) or
    /// settles the row as `.failed` with a written message.
    ///
    /// A re-arm re-submits the *same* URL, which the row still carries now
    /// that `pendingDownloadURLString` survives admission — so none of
    /// `enqueue`'s artwork/subtitle/trickplay/chapter prep is re-run, and
    /// the transcode poll loop deliberately keeps running across the backoff
    /// window, because its keep-alive ping is what stops Jellyfin's 10-second
    /// kill timer destroying the server-side job we intend to reconnect to.
    ///
    /// Reusing the URL means reusing its `PlaySessionId`, and therefore the
    /// server's transcode cache entry for it. That is what we *want* when
    /// the job is still alive (the -997 case: the client's channel broke,
    /// the server's encode did not), and it is safe when it isn't, because
    /// `finalizeCompletedDownload` already rejects a short file via
    /// `durationValidationFailureReason`. Minting a fresh `PlaySessionId`
    /// would need a live `JellyfinAPIClient`, which this type deliberately
    /// never stores and which doesn't exist at all during launch adoption —
    /// that escape hatch stays where it already is, on the user-initiated
    /// `retry(itemID:client:)`.
    private func resolveFailedDownload(itemID: String, error: Error) {
        guard let row = store.item(itemID: itemID) else {
            automaticRetryAttempts[itemID] = nil
            stopTranscodeProgressPolling(itemID: itemID)
            return
        }
        let attempt = automaticRetryAttempts[itemID, default: 0]
        let canRetry = Self.isRetryableTransportError(error)
            && attempt < automaticRetryBackoff.count
            && row.pendingDownloadURLString != nil
            && !row.markedForDeletion
        guard canRetry else {
            stopTranscodeProgressPolling(itemID: itemID)
            automaticRetryAttempts[itemID] = nil
            // A row that only still exists to carry an unsynced watched/
            // resume write shouldn't be relabelled as a failed download.
            guard !row.markedForDeletion else { return }
            row.status = .failed
            row.errorMessage = Self.friendlyDownloadFailureMessage(for: error)
            store.save()
            return
        }
        automaticRetryAttempts[itemID] = attempt + 1
        row.status = .queued
        row.errorMessage = nil
        store.save()
        let delay = automaticRetryBackoff[attempt]
        retryTasks[itemID]?.cancel()
        retryTasks[itemID] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.retryTasks[itemID] = nil
            self.queueVideoDownload(itemID: itemID)
        }
    }

    /// Runs once the transfer itself succeeded (a good HTTP status, the file
    /// already moved into place by `DownloadTaskRouter`) but before
    /// trusting that as a genuinely complete download — see
    /// `validationFailureReason(relativePath:expectedRuntimeTicks:)`'s own
    /// doc comment for why that isn't automatic. A row deleted mid-transfer
    /// (`store.item(itemID:)` returns `nil`) has nothing left to update.
    private func finalizeCompletedDownload(itemID: String, relativePath: String) async {
        guard let row = store.item(itemID: itemID) else { return }
        if let failureReason = await Self.validationFailureReason(relativePath: relativePath, expectedRuntimeTicks: row.runtimeTicks) {
            // Otherwise a `.failed` row would still point at a real,
            // playable-up-to-where-it-stopped file — confirmed live
            // (2026-08-27): exactly what made the underlying bug this
            // guards against invisible in the first place.
            try? FileManager.default.removeItem(at: DownloadFileStore.url(forRelativePath: relativePath))
            row.status = .failed
            row.errorMessage = failureReason
        } else {
            row.status = .completed
            row.errorMessage = nil
        }
        store.save()
    }

    /// `nil` when the downloaded file's own actual duration is close enough
    /// to what `expectedRuntimeTicks` (the item's known runtime, set at
    /// enqueue time) says it should be; a user-facing reason otherwise.
    ///
    /// This exists because a transcode's HTTP response has no
    /// `Content-Length` (chunked, per `DOWNLOADS.md`) and, empirically,
    /// closes the same way whether ffmpeg finished normally or crashed
    /// partway through — confirmed live (2026-08-27): a VideoToolbox
    /// `scale_vt` crash on a Dolby Vision source under concurrent transcode
    /// load produced a perfectly valid, HTTP-200, *playable* four-minute
    /// MP4 for a 134-minute film, and `URLSessionDownloadTask` reported it
    /// as a completed transfer. `DownloadTaskRouter`'s existing
    /// HTTP-status check only catches an outright error response, not a
    /// stream that ends early while still claiming success — this is the
    /// second check that closes that gap.
    private static func validationFailureReason(relativePath: String, expectedRuntimeTicks: Int64?) async -> String? {
        guard let expectedRuntimeTicks, expectedRuntimeTicks > 0 else { return nil }
        let expectedSeconds = Double(expectedRuntimeTicks) / 10_000_000
        let asset = AVURLAsset(url: DownloadFileStore.url(forRelativePath: relativePath))
        let actualSeconds: Double
        do {
            actualSeconds = try await asset.load(.duration).seconds
        } catch {
            return String(localized: "The downloaded video couldn't be verified. Try downloading again.")
        }
        return durationValidationFailureReason(actualSeconds: actualSeconds, expectedSeconds: expectedSeconds)
    }

    /// The actual decision logic behind `validationFailureReason(relativePath:
    /// expectedRuntimeTicks:)`, split out as a pure function so it's directly
    /// unit-testable without touching `AVFoundation`/real files — this
    /// codebase's own convention for the download engine (`DownloadManagerTests`'
    /// own doc comment: the real background `URLSessionDownloadTask`/delegate
    /// machinery isn't unit-tested; the logic that decides what it means is).
    /// Not `private` for the same reason `isHDR` isn't — a test target needs
    /// to call it directly.
    static func durationValidationFailureReason(actualSeconds: Double, expectedSeconds: Double) -> String? {
        guard actualSeconds.isFinite, actualSeconds > 0 else {
            return String(localized: "The downloaded video couldn't be verified. Try downloading again.")
        }
        guard actualSeconds >= expectedSeconds * durationValidationMinimumFraction else {
            let actualMinutes = Int(actualSeconds / 60)
            let expectedMinutes = Int(expectedSeconds / 60)
            return String(localized: "The download stopped early (only \(actualMinutes) of \(expectedMinutes) minutes were saved). Try downloading again.")
        }
        return nil
    }

    /// How much of the expected runtime a downloaded file must actually
    /// contain to count as complete. Not exactly 100% — a real transcode's
    /// output can legitimately land a fraction of a second short of the
    /// source's own `RunTimeTicks` (keyframe/mux rounding at the very end),
    /// so a hard equality check would produce false failures on perfectly
    /// good downloads. 95% comfortably clears that noise floor while still
    /// catching a catastrophically short file by a wide margin — Captain
    /// Phillips' truncated download was ~3% of its expected runtime.
    static let durationValidationMinimumFraction = 0.95

    // MARK: - Live transcode-progress polling

    /// Runs two independent jobs every `transcodeProgressPollInterval` for
    /// the life of one download's video transfer:
    ///
    /// 1. **Keep-alive ping** (`JellyfinAPIClient.pingDownloadTranscode`) —
    ///    unconditional, for every download including a stream-copy one
    ///    (still a `Progressive`-type job server-side, still subject to the
    ///    same kill timer). Confirmed live (2026-08-27): a real, transient
    ///    connection stall under concurrent-download CPU contention gets
    ///    read by Jellyfin as the client disconnecting, which arms a
    ///    10-second kill timer on the still-wanted transcode job — and
    ///    without a ping on the same `PlaySessionId`, nothing refreshes it,
    ///    so the job dies and a later automatic reconnect has to start an
    ///    entirely new transcode from byte zero (confirmed via the actual
    ///    server logs: three full independent re-encodes of the same
    ///    12-minute stretch of one episode, each ended by exactly this kill
    ///    timer). Pinging every two seconds — well inside that 10-second
    ///    window — keeps the job alive through a stall so a reconnect just
    ///    reattaches to the same in-progress job instead.
    /// 2. **Live completion percentage** — see
    ///    `DownloadProgress.transcodeCompletionPercentage`'s doc comment for
    ///    why this exists. Uses `currentSession(deviceID:)` directly rather
    ///    than matching a specific item/session out of a list — confirmed
    ///    live that Jellyfin never populates `NowPlayingItem`/
    ///    `PlayState.MediaSourceId` for a plain transcode-stream request the
    ///    way it does for a real playback session, so an item-matching
    ///    filter here would silently match nothing, every time. This
    ///    device only ever has one session row regardless (matches
    ///    `currentSession(deviceID:)`'s own doc comment), so using it
    ///    directly is both correct and simpler — but it also means two
    ///    *concurrent* downloads (`DownloadPreferencesStore
    ///    .maxConcurrentDownloads` defaults to 3, so this is common, not
    ///    rare) share that one `TranscodingInfo`, clobbered by whichever job
    ///    reported last — confirmed live by running two transcodes at once
    ///    from the same `DeviceId`. Applying that value to *this* item's
    ///    progress when another transcoding download is also active would
    ///    be actively wrong, not just imprecise, so it's only trusted while
    ///    `transcodeProgressPollTasks.count == 1`; every download falls back
    ///    to its own (per-item, always-correct) byte estimate whenever more
    ///    than one transcode is active.
    ///
    /// Uses `client` as handed to `enqueue`/`retry` at call time rather
    /// than a client stored on this manager — `DownloadManager` is
    /// deliberately never given a long-lived client reference (see
    /// `onRowMarkedForDeletion`'s doc comment: unlike `AppState.apiClient`,
    /// this manager outlives sign-in/sign-out/server changes, so a stored
    /// client would go stale). The trade-off: a download reattached after a
    /// relaunch (`adoptInFlightDownloads`/`handleBackgroundSessionEvents`,
    /// both of which run before any client exists) never gets this loop at
    /// all — no ping, no live percentage — and falls back to whatever the
    /// background `URLSessionDownloadTask` itself can recover on its own.
    /// That's a real gap specifically for the kill-timer problem (a
    /// relaunch-reattached download has no protection against it), not just
    /// the display-only limitation it was before this ping existed.
    ///
    /// A failed ping or poll (network hiccup, sign-out mid-download) is
    /// silently skipped rather than treated as an error — both are
    /// best-effort, and a single missed tick two seconds before the next
    /// one is immaterial either way.
    private func startTranscodeProgressPolling(itemID: String, playSessionId: String, client: JellyfinAPIClient) {
        transcodeProgressPollTasks[itemID]?.cancel()
        transcodeProgressPollTasks[itemID] = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.transcodeProgressPollInterval)
                guard !Task.isCancelled, let self else { return }
                try? await client.pingDownloadTranscode(playSessionId: playSessionId)
                guard var progress = self.activeDownloads[itemID] else { continue }

                // See the doc comment above: only trust the shared session's
                // percentage while this is the only transcoding download in
                // flight — otherwise it may belong to a different item.
                guard self.transcodeProgressPollTasks.count == 1 else {
                    // Confirmed live (2026-08-27): without this, a value set
                    // while this WAS the only transcoding download (e.g.
                    // ~50%) simply froze there the instant a second download
                    // started — `fractionCompleted` always prefers this
                    // field over the byte estimate, and nothing was clearing
                    // it just because it could no longer be trusted, so the
                    // ring sat pinned to a stale number while the real byte
                    // count kept climbing underneath, right up until the
                    // item actually finished. Clearing it here lets display
                    // fall back to the byte estimate — imprecise, but never
                    // frozen or wrong — for as long as the ambiguity lasts.
                    if progress.transcodeCompletionPercentage != nil {
                        progress.transcodeCompletionPercentage = nil
                        self.activeDownloads[itemID] = progress
                    }
                    continue
                }
                guard let session = try? await client.currentSession(deviceID: DeviceIdentity.deviceID),
                      let percentage = session.transcodingInfo?.completionPercentage
                else { continue }
                progress.transcodeCompletionPercentage = percentage
                self.activeDownloads[itemID] = progress
            }
        }
    }

    /// Also drops any *staged* starter (`pendingPollStarters`) — an item
    /// deleted while still queued never ran its loop, but would otherwise
    /// leave a closure holding a `JellyfinAPIClient` alive for the life of
    /// this manager.
    private func stopTranscodeProgressPolling(itemID: String) {
        transcodeProgressPollTasks[itemID]?.cancel()
        transcodeProgressPollTasks[itemID] = nil
        pendingPollStarters[itemID] = nil
    }

    // MARK: - Delete

    /// Always frees the on-disk video/subtitle files, and each of the four
    /// possibly-shared image fields only if no other row still references
    /// it (`DownloadFileStore.deleteImageIfUnreferenced`). The row itself
    /// is removed immediately unless it still has an unsynced watched/
    /// resume write (`pendingSync`), in which case it survives with
    /// `markedForDeletion = true` purely to carry that write — see
    /// `DownloadSyncManager`, which removes it for real once the sync
    /// succeeds.
    ///
    /// Also cancels the item's in-flight background session, if any —
    /// leaving a `.downloading` row's underlying `URLSessionDownloadTask`
    /// running orphaned at the OS level (background transfers don't stop
    /// just because this manager drops its delegate reference) meant a
    /// same-day redownload could reuse the same deterministic session
    /// identifier while the OS still considered it in use, cancelling the
    /// new session's task (`NSURLErrorCancelled`/-999). Invalidating here
    /// frees the identifier for real.
    func delete(itemID: String) {
        guard let downloaded = store.item(itemID: itemID) else { return }
        DownloadFileStore.deleteItemFiles(itemID: itemID)
        // Fetched once and reused across every check below, rather than each
        // independently re-fetching the full table.
        let allItems = store.allItems()
        // Chapter stills live in the same shared, content-addressed image
        // pool as the four fields above (they're per-item in practice, but
        // the pool's reference check is what decides that, not this call
        // site), so they need the same guarded unlink rather than a blind
        // delete — without this they'd simply leak on every deletion.
        let sharedImagePaths = [
            downloaded.posterImagePath, downloaded.backdropImagePath, downloaded.logoImagePath, downloaded.thumbImagePath
        ] + downloaded.chapters.map(\.imageRelativePath)
        for path in sharedImagePaths {
            DownloadFileStore.deleteImageIfUnreferenced(relativePath: path, excludingItemID: itemID, store: store, among: allItems)
        }
        // `activeItemIDs.remove` returning non-nil is exactly "this item's
        // transfer actually started", so gating the cancel on it keeps this
        // a no-op for a row that was still `.queued` and never got as far as
        // a real task to cancel. Removing it here also makes any callback
        // that arrives after this deletion a no-op in
        // `handleDownloadCompletion` — including the `NSURLErrorCancelled`
        // the cancel below provokes, which used to write `.failed` onto a
        // row that had just been deleted.
        let wasActivelyDownloading = activeItemIDs.remove(itemID) != nil
        activeDownloads[itemID] = nil
        stopTranscodeProgressPolling(itemID: itemID)
        automaticRetryAttempts[itemID] = nil
        retryTasks.removeValue(forKey: itemID)?.cancel()
        if wasActivelyDownloading {
            if let cancelVideoDownloadOverride {
                cancelVideoDownloadOverride(itemID)
            } else {
                downloadTasks.removeValue(forKey: itemID)?.cancel()
                // Belt and braces for the window between `init` and
                // `finishAdopting`, where a transfer adopted from a previous
                // launch is genuinely live but not yet recorded in
                // `downloadTasks`. Cancelling the *task* rather than
                // invalidating a session is the whole difference from the
                // old scheme: there is no longer a per-item identifier to
                // free, only a transfer that must stop writing bytes into a
                // directory this deletion just removed.
                backgroundSession.getAllTasks { tasks in
                    tasks.filter { $0.taskDescription == itemID }.forEach { $0.cancel() }
                }
            }
        }
        // Only meaningful for a row that was still waiting for a
        // concurrency slot (never got as far as starting a real
        // `URLSessionDownloadTask`) — a harmless no-op otherwise.
        pendingQueue.removeAll { $0 == itemID }

        if downloaded.pendingSync {
            downloaded.markedForDeletion = true
            store.save()
            // Nudges DownloadSyncManager immediately rather than waiting
            // for the next scenePhase trigger — see `onRowMarkedForDeletion`'s
            // own doc comment.
            onRowMarkedForDeletion?()
        } else {
            store.delete(downloaded)
        }
        // A `.downloading` row just had its concurrency slot freed above
        // (`activeItemIDs.remove`) — admit whatever's next in line
        // immediately rather than leaving it `.queued` until some other,
        // unrelated event happens to call this.
        admitQueuedDownloadsIfPossible()
    }

    #if DEBUG
    // MARK: - Test seam (DownloadManagerTests only — see `startVideoDownloadOverride`)

    /// Frees a concurrency slot and admits the next queued item, mirroring
    /// the bookkeeping half of `handleDownloadCompletion`. Deliberately not
    /// routed through the real success branch: that would kick off
    /// `finalizeCompletedDownload`'s `AVURLAsset` load against a file no
    /// unit test has written, which is exactly the real-IO this suite
    /// excludes. Compiled out of Release.
    func test_simulateDownloadFinished(itemID: String) {
        guard activeItemIDs.remove(itemID) != nil else { return }
        activeDownloads[itemID] = nil
        downloadTasks[itemID] = nil
        stopTranscodeProgressPolling(itemID: itemID)
        automaticRetryAttempts[itemID] = nil
        admitQueuedDownloadsIfPossible()
    }

    /// Drives the failure half of `handleDownloadCompletion` — the automatic
    /// retry classification, budget and slot accounting — without a real
    /// transfer to fail. Compiled out of Release.
    func test_simulateDownloadFailed(itemID: String, error: Error) {
        handleDownloadCompletion(itemID: itemID, result: .failure(error))
    }

    /// How many transcode poll loops are actually running — lets a test
    /// assert that a merely-queued item doesn't start one. Compiled out of
    /// Release.
    var test_activeTranscodePollCount: Int { transcodeProgressPollTasks.count }
    #endif
}

extension Notification.Name {
    static let dionysusHandleBackgroundURLSession = Notification.Name("dionysusHandleBackgroundURLSession")
}

/// Keys into the `userInfo` dictionary posted alongside
/// `.dionysusHandleBackgroundURLSession` — see `AppDelegate.application(_:
/// handleEventsForBackgroundURLSession:completionHandler:)`.
enum DionysusBackgroundURLSessionUserInfoKey {
    static let identifier = "identifier"
    static let completionHandler = "completionHandler"
}

/// UIKit's background-session completion handler is a plain `() -> Void`,
/// not marked `@Sendable` — this wraps it so it can safely cross into
/// `DownloadManager`'s `@MainActor` isolation via `NotificationCenter`,
/// whose block-based API requires a `@Sendable` payload.
/// `@unchecked Sendable` is safe here: the wrapped closure is only ever
/// invoked once, on the main thread — posted by `AppDelegate.application(_:
/// handleEventsForBackgroundURLSession:completionHandler:)`, consumed by
/// `DownloadManager.init`'s observer, both main-thread-only by contract
/// (UIKit calls the former on main, and the observer is registered with
/// `queue: .main`).
final class BackgroundSessionCompletionBox: @unchecked Sendable {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
}
