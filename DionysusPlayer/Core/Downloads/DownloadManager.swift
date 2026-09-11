import AVFoundation
import Foundation
import Observation

/// Live progress for one in-flight download, bound by `DownloadsView` and
/// `DownloadButton`. In memory only — persisting per `didWriteData` tick would
/// be dozens of SwiftData writes a second; the row is updated at completion.
struct DownloadProgress: Equatable {
    var bytesDownloaded: Int64
    /// A live-transcode stream (`Static=false`) carries no real
    /// `Content-Length`, so this is usually `DownloadedItem
    /// .estimatedTotalBytes`, computed from bitrate and runtime at enqueue.
    /// `<= 0` when even that estimate was unavailable.
    var totalBytesExpected: Int64
    /// Jellyfin's `TranscodingInfo.CompletionPercentage` (0...100), polled by
    /// `DownloadManager.startTranscodeProgressPolling`. Encode-timeline
    /// progress, so unlike the byte estimate it is immune to
    /// content-adaptive-bitrate variance, which leaves that estimate anywhere
    /// from ~46% to ~95% at true completion (see DOWNLOADS.md).
    ///
    /// `nil` for a stream copy, before the first poll lands, or for a download
    /// reattached after relaunch, which has no signed-in client yet.
    var transcodeCompletionPercentage: Double? = nil

    var isTotalKnown: Bool { totalBytesExpected > 0 }

    /// Whether `fractionCompleted` reflects a real measurement rather than `0`.
    var isDeterminate: Bool { transcodeCompletionPercentage != nil || isTotalKnown }

    /// Preferring `transcodeCompletionPercentage` over the byte estimate, and
    /// capped just short of full either way: completion is signalled only by
    /// the transfer's own callback, so this must not read "done" before it.
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
    /// `retry(itemID:client:)`-specific: the item has since been removed from
    /// the server, so there is nothing left to re-fetch.
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

/// Downloads and deletes offline copies of Jellyfin items — device-transcoded
/// video, sidecar subtitles, and a metadata/artwork snapshot — via
/// `DownloadFileStore`/`DownloadStore`.
@MainActor
@Observable
final class DownloadManager: NSObject {
    private(set) var activeDownloads: [String: DownloadProgress] = [:]

    /// Unfinished rows, for `MainTabView`'s Downloads tab badge. Reads
    /// `store.changeCount` rather than `activeDownloads` so it also counts
    /// `.queued` rows awaiting a concurrency slot, which never reach
    /// `activeDownloads`. `.paused` is unset today but belongs in this bucket.
    var pendingOrActiveDownloadsCount: Int {
        _ = store.changeCount
        let pendingStatuses: Set<DownloadStatus> = [.queued, .downloading, .paused]
        return store.visibleItems().filter { pendingStatuses.contains($0.status) }.count
    }

    /// Nudges `DownloadSyncManager` when `delete(itemID:)` leaves a row
    /// `markedForDeletion`, rather than waiting for the next scenePhase
    /// trigger. A closure, not a stored client: this manager outlives
    /// sign-in/sign-out and server changes, so a stored client would go stale.
    var onRowMarkedForDeletion: (() -> Void)?

    /// Non-`private` so the Downloads UI can read rows without pass-through
    /// methods. Writes still go only through `enqueue`/`delete`.
    let store: DownloadStore
    /// The app's one background session identifier. `DownloadTaskRouter`
    /// documents the -997 "lost connection to the background transfer service"
    /// failure that a session per item produced.
    private static let backgroundSessionIdentifier = "com.dionysus.downloads"
    /// Identifiers from the superseded session-per-item scheme, kept so
    /// `sweepLegacyPerItemSessions` can reclaim sessions still live in
    /// `nsurlsessiond` and a background relaunch can answer their completion
    /// handlers. Removable once a few releases have shipped.
    private static let legacyPerItemSessionIdentifierPrefix = "com.dionysus.downloads."
    /// Covers both the initial warm-up, while a Jellyfin transcode job spins
    /// up, and any later gap: `timeoutIntervalForRequest` resets on each
    /// received chunk rather than bounding the connect alone. Sized above the
    /// stalls seen under concurrent-download CPU contention, but kept finite so
    /// a dead connection still fails well before `downloadResourceTimeout`.
    private static let downloadRequestTimeout: TimeInterval = 120
    /// Bounds the whole fetch, not just the warm-up — a 4K transcode is slow.
    private static let downloadResourceTimeout: TimeInterval = 60 * 60 * 6
    /// Concurrent trickplay tile-sheet fetches, bounded so they don't compete
    /// with the video transcode over the same connection.
    private static let maxConcurrentTrickplaySheetDownloads = 4

    /// One long-lived session for the small fetches alongside a download
    /// (subtitles, artwork, trickplay tiles), so `DownloadPreferencesStore
    /// .wifiOnly` gates them as well as the video transfer.
    ///
    /// The Wi-Fi gate lives on the request (`makeFetchRequest(url:)`), not this
    /// configuration: it is re-evaluated per fetch, so a preference change
    /// takes effect immediately against a single session, and
    /// `allowsExpensiveNetworkAccess` also covers a personal hotspot.
    private let adHocFetchSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        // Permitted here; the real gate is per-request in `makeFetchRequest`.
        configuration.allowsCellularAccess = true
        #if DEBUG
        UITestHarness.decorate(configuration)
        #endif
        return URLSession(configuration: configuration)
    }()

    /// Applies `DownloadPreferencesStore.wifiOnly` to one request. A transfer's
    /// effective policy is the AND of session and request flags, so gating here
    /// suffices. `allowsExpensiveNetworkAccess` covers a personal hotspot,
    /// which iOS reports as expensive rather than cellular.
    private func makeFetchRequest(url: URL) -> URLRequest {
        Self.makeFetchRequest(url: url, allowsCellularAccess: !preferences.wifiOnly)
    }

    /// `nonisolated static` so `downloadChapterImages`/`downloadTrickplayTiles`
    /// task groups can build requests without hopping to this `@MainActor`
    /// type. Non-`private` for `DownloadManagerTests`.
    nonisolated static func makeFetchRequest(url: URL, allowsCellularAccess: Bool) -> URLRequest {
        var request = URLRequest(url: url)
        request.allowsCellularAccess = allowsCellularAccess
        request.allowsExpensiveNetworkAccess = allowsCellularAccess
        return request
    }

    /// The single delegate behind `backgroundSession`, retained here because
    /// that session is never invalidated.
    private let router = DownloadTaskRouter()
    /// The app's one background `URLSession`, kept for the process lifetime and
    /// never invalidated. `lazy` so tests driving the queue through
    /// `startVideoDownloadOverride` never construct one; `@ObservationIgnored`
    /// because `@Observable` can't make a tracked property `lazy`.
    @ObservationIgnored private lazy var backgroundSession: URLSession = {
        URLSession(configuration: Self.makeBackgroundConfiguration(), delegate: router, delegateQueue: nil)
    }()
    /// Item IDs whose video transfer is running: the in-flight count for
    /// `canStartAnotherDownload`, and the once-only gate that makes completion
    /// handling idempotent.
    private var activeItemIDs: Set<String> = []
    /// Live download tasks by itemID, so `delete(itemID:)` can cancel a
    /// transfer. A cache, not the source of truth — the session's own task list
    /// is, which is why `delete` also sweeps `getAllTasks` for tasks adopted at
    /// launch but not yet recorded here.
    private var downloadTasks: [String: URLSessionDownloadTask] = [:]
    /// Stashed by a background relaunch (`handleBackgroundSessionEvents`) and
    /// called once the session reports every queued callback delivered.
    /// Answering it is unconditional: an unanswered handler costs the app
    /// background time on the next launch.
    private var backgroundCompletionHandler: (() -> Void)?
    /// Item IDs awaiting a concurrency slot, FIFO, popped by
    /// `admitQueuedDownloadsIfPossible`. Narrower than "every `.queued` row":
    /// an item is `.queued` but absent here while `enqueue` fetches subtitles.
    private var pendingQueue: [String] = []
    /// Live-transcode-progress poll loops by itemID (see
    /// `startTranscodeProgressPolling`), cancelled when a download finishes,
    /// fails, or is deleted.
    private var transcodeProgressPollTasks: [String: Task<Void, Never>] = [:]
    /// Deferred `startTranscodeProgressPolling` calls by itemID, staged by
    /// `enqueue` and fired by `admitQueuedDownloadsIfPossible` once the item
    /// actually starts transferring.
    ///
    /// Polling must not start at queue time: a waiting item has no server-side
    /// transcode job, so it would ping `/Sessions/Playing/Ping` for an unknown
    /// `PlaySessionId`, and — since the loop only trusts the device's shared
    /// `TranscodingInfo` while `transcodeProgressPollTasks.count == 1` —
    /// queueing anything would suppress the live percentage for the download
    /// that is running.
    ///
    /// A closure rather than the `playSessionId`/`client` pair it captures, so
    /// the client stays alive only while this item is queued or downloading
    /// (see `onRowMarkedForDeletion`).
    private var pendingPollStarters: [String: () -> Void] = [:]
    /// How often `startTranscodeProgressPolling` re-checks `/Sessions` and
    /// sends its keep-alive ping: inside Jellyfin's 10-second transcode kill
    /// timer, without competing with the transcode for the connection.
    private static let transcodeProgressPollInterval: Duration = .seconds(2)
    /// Automatic re-arm count per item after a transport failure (see
    /// `isRetryableTransportError`), plus the scheduled re-arms.
    ///
    /// In memory rather than persisted: the budget bounds one automatic loop
    /// against a process- or daemon-lifetime fault, so reopening the app should
    /// grant fresh attempts. The trade-off is that a hopeless item spends its
    /// budget once per launch, landing visibly `.failed` each time.
    private var automaticRetryAttempts: [String: Int] = [:]
    private var retryTasks: [String: Task<Void, Never>] = [:]
    /// Backoff between automatic re-arms; its `count` is the budget. The first
    /// step stays inside Jellyfin's 10-second transcode kill timer, so a re-arm
    /// reattaches to the running job instead of provoking a fresh encode.
    /// Injectable so tests can drive the budget without waiting.
    private let automaticRetryBackoff: [Duration]
    /// Injectable so tests can drive `maxConcurrentDownloads` without mutating
    /// `UserDefaults.standard`.
    private let preferences: DownloadPreferencesStore
    /// Test seam for `admitQueuedDownloadsIfPossible`'s FIFO and concurrency
    /// bookkeeping, without a network call or background session. Injected via
    /// `init` so it is in place before `resumePendingQueue()` runs.
    private let startVideoDownloadOverride: ((String, URL, String) -> Void)?
    /// Test seam: `delete(itemID:)` calls this instead of cancelling the task.
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
            // `queue: .main` already guarantees the main thread;
            // `assumeIsolated` asserts it instead of hopping through a `Task`.
            MainActor.assumeIsolated {
                self?.handleBackgroundSessionEvents(identifier: identifier, completionHandler: box.handler)
            }
        }
        // Sweeps files left behind by a deleted row whose download task kept
        // writing afterwards.
        DownloadFileStore.deleteOrphanedItemDirectories(knownItemIDs: Set(store.allItems().map(\.itemID)))
        // Before `resumePendingQueue()`: reserving in-flight rows' concurrency
        // slots first stops the admission pass overshooting the limit.
        sweepLegacyPerItemSessions()
        adoptInFlightDownloads()
        resumePendingQueue()
    }

    convenience override init() {
        self.init(store: .makeDefault())
    }

    // MARK: - Enqueue

    /// `mediaSource`/`audioTrack`/`subtitleTracks` come from the caller's own
    /// `playbackInfo` fetch and prompts; this neither re-fetches nor re-prompts.
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
        // AUDIO SUPPRESSION: unreachable today — `DownloadButton` appears only
        // in `MovieDetailView`, which `AssetDetailView` never renders for audio.
        // Guards a future bulk or library-level entry point. Delete once audio
        // downloads are supported.
        guard !item.isAudioContent else { throw DownloadError.audioContentNotSupported }
        guard let mediaSourceID = mediaSource.id else { throw DownloadError.missingMediaSource }
        // A redownload starts from a clean slate rather than letting
        // SwiftData's unique-key merge reconcile the rows: a partial merge can
        // leave stored metadata describing the new quality while the on-disk
        // video is still the old one. Not airtight — a row with an unsynced
        // `pendingSync` write survives `delete` as `markedForDeletion`.
        if store.item(itemID: item.id) != nil {
            delete(itemID: item.id)
        }
        let streams = mediaSource.mediaStreams ?? []
        let videoStream = streams.first { $0.type == "Video" }
        let isSourceHDR = Self.isHDR(videoStream)
        // The video track's own bitrate, not `mediaSource.bitrate`, which
        // covers the whole container: feeding that to a video-only cap
        // overshoots by the weight of the audio tracks. Falls back to the
        // container figure only when no per-stream figure was reported.
        let sourceVideoBitrate = videoStream?.bitRate ?? mediaSource.bitrate
        // One per download, threaded through both the stream request and the
        // keep-alive ping loop (see `JellyfinAPIClient.pingDownloadTranscode`).
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
            // Permanently `false`, not a placeholder: downloads always
            // transcode, and Jellyfin's transcoder has no HDR-to-HDR output —
            // any re-encode is tone-mapped to SDR regardless of `DeviceProfile`.
            // Preserving HDR would need an uncapped stream-copy download path.
            isHDR: false,
            selectedAudioTrackIndex: audioTrack?.index,
            selectedAudioTrackTitle: audioTrack?.displayTitle,
            videoFilePath: DownloadFileStore.videoRelativePath(itemID: item.id),
            skippedSubtitleTracks: subtitleTracks
                .filter { JellyfinAPIClient.isImageBasedSubtitleCodec($0.codec) }
                .map { $0.displayTitle ?? String(localized: "Track \($0.index + 1)") },
            // Not `.downloading` until `queueVideoDownload` admits it past
            // `maxConcurrentDownloads`. `pendingDownloadURLString` lets that
            // admission, even after a relaunch, recover this URL.
            status: .queued,
            pendingDownloadURLString: downloadURL.absoluteString,
            metadata: metadata
        )
        // Before the artwork/segments/trickplay fetches, which take seconds
        // against a cold server: `DownloadButton`/`SeasonDownloadButton` need a
        // row to key `isPreparing` off. Backfilled once those resolve.
        store.insert(downloaded)

        let images = await client.makeImageURLBuilder()
        // Independent of each other, so fetched concurrently rather than
        // serially delaying the video transfer.
        async let posterPathTask = downloadImageIfNeeded(sourceItemID: item.id, imageType: "Primary", tag: item.dto.imageTags?["Primary"], maxWidth: 500, images: images)
        // Own image if present, else the nearest ancestor's — the fallback
        // `MediaItem.backdropImageURL`/`logoImageURL` apply live.
        async let backdropPathTask = resolveBackdropPath(for: item, images: images)
        async let logoPathTask = resolveLogoPath(for: item, images: images)
        async let thumbPathTask = downloadImageIfNeeded(sourceItemID: item.id, imageType: "Thumb", tag: item.dto.imageTags?["Thumb"], maxWidth: 500, images: images)
        async let segmentDTOsTask = (try? await client.mediaSegments(itemID: item.id)) ?? []
        async let trickplayInfoTask = downloadTrickplayTiles(itemID: item.id, mediaSourceID: mediaSourceID, client: client, userID: userID, images: images)
        // Already populated: `JellyfinAPIClient.detailFields` carries
        // `Chapters`, so this needs no extra fetch the way trickplay does.
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

        // Staged, not started — see `pendingPollStarters`. The loop begins when
        // `queueVideoDownload` admits this item past the concurrency limit.
        pendingPollStarters[item.id] = { [weak self] in
            // Every download, not just a re-encode: a stream copy is still a
            // `Progressive` job subject to the same kill timer, so it needs the
            // keep-alive ping. It simply reports no completion percentage.
            self?.startTranscodeProgressPolling(itemID: item.id, playSessionId: playSessionId, client: client)
        }
        queueVideoDownload(itemID: item.id)
    }

    /// Re-attempts a `.failed` download with the original resolution, quality
    /// and audio-track choices, without re-prompting. A no-op unless the row is
    /// `.failed`. Needs a live `client` — the offline Downloads pages this is
    /// called from work without a session, so callers must gate on that.
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
        // The originally chosen index if this negotiation still offers it,
        // else the first-time-download fallback (default, then first), rather
        // than failing the retry over a reshuffled track list.
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

    /// The fetch-time half of the shared-artwork dedup: reuses a file already
    /// downloaded for this `(sourceItemID, imageType, tag)` identity.
    ///
    /// A `nil` tag means "untagged", not "skip" — an episode routinely has no
    /// `imageTags["Primary"]` yet still serves a still frame. Checks the HTTP
    /// status explicitly because `URLSession.data(from:)` doesn't throw on a
    /// 404, which would write the error body to disk as image data.
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

    /// Own backdrop if present, else the nearest ancestor's, matching
    /// `MediaItem.backdropImageURL`'s live fallback. A function so `enqueue`
    /// can start it as one `async let` alongside its other artwork fetches.
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

    /// Fetches this item's trickplay track and tile-sheet JPEGs for
    /// `OfflineTrickplayThumbnailProvider` — the offline counterpart to
    /// `TrickplayThumbnailProvider`. Re-fetches the item with
    /// `detailFieldsWithTrickplay`, which the caller's DTO lacks.
    ///
    /// Best-effort: `nil` if there is no track or the lookup fails, and a
    /// single failed sheet is non-fatal.
    private func downloadTrickplayTiles(
        itemID: String, mediaSourceID: String, client: JellyfinAPIClient, userID: String, images: ImageURLBuilder
    ) async -> TrickplayInfo? {
        guard let dto = try? await client.item(userID: userID, itemID: itemID, fields: JellyfinAPIClient.detailFieldsWithTrickplay),
              let info = TrickplayMath.bestInfo(from: dto.trickplay, mediaSourceID: mediaSourceID)
        else { return nil }

        let sheetCount = TrickplayMath.sheetCount(for: info)
        guard sheetCount > 0 else { return nil }
        // Hoisted and captured by value so the child tasks below never cross
        // back to this `@MainActor` type; `URLSession` is `Sendable`.
        let session = adHocFetchSession
        let allowsCellularAccess = !preferences.wifiOnly
        // Sheet indices are independent, so fetch them concurrently up to
        // `maxConcurrentTrickplaySheetDownloads`.
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

    /// Captures chapter markers and still frames into the shared image pool,
    /// for the offline detail page's Chapters rail and the player's chapter
    /// picker. The chapter counterpart to `downloadTrickplayTiles`.
    ///
    /// Best-effort per chapter: a missing image leaves `imageRelativePath` nil,
    /// rendering as `MediaPlaceholderBox`. A chapter with no `imageTag` is
    /// never attempted — for chapters that is Jellyfin's definitive "no image",
    /// unlike the tagless-but-served Primary images `downloadImageIfNeeded`
    /// allows.
    ///
    /// Takes mapped `[Chapter]` rather than DTOs so the "a single dummy chapter
    /// means no chapters" rule lives only in `MediaItem.chapters`.
    ///
    /// Concurrent up to `maxConcurrentTrickplaySheetDownloads`: a feature film
    /// carries 30+ chapters and this batch is awaited before the video transfer
    /// starts. Re-sorted afterwards, since a task group completes out of order.
    private func downloadChapterImages(itemID: String, chapters: [Chapter], images: ImageURLBuilder) async -> [DownloadedChapter] {
        // Hoisted so each child task runs `nonisolated`. Without it, every
        // chapter's ~100KB `DownloadFileStore.write` would be a synchronous
        // main-thread disk write, 30+ times for a feature film.
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

    /// One chapter still, under the usual content-addressed
    /// `(sourceItemID, imageType, tag)` identity but with the chapter index
    /// folded into the type segment (`"Chapter0"`, …): an item's chapters often
    /// share one `imageTag`, which a plain `"Chapter"` would collapse into a
    /// single file. Separate from `downloadImageIfNeeded` because this route
    /// also needs the index in its URL.
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
            // A 404 is expected here: an older server can report a phantom tag
            // for a chapter with no image. Checked explicitly because
            // `URLSession.data(from:)` doesn't throw on one.
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else { return nil }
            try DownloadFileStore.write(data, toRelativePath: relativePath)
            return relativePath
        } catch {
            return nil
        }
    }

    /// Replaces raw system error strings for the failures users actually hit.
    /// Force-quitting the app cancels its background transfers by design, so
    /// `NSURLErrorCancelled` on reattachment is expected rather than a bug —
    /// distinct from the OS killing a backgrounded app, which
    /// `adoptInFlightDownloads` recovers from.
    ///
    /// The background-session cases are reached only after
    /// `resolveFailedDownload` has spent the automatic retry budget, hence
    /// "after several attempts". They otherwise surface iOS's own "Lost
    /// connection to the background transfer service", which reads as an app
    /// defect and names a component users can't act on.
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

    /// Non-`private`: `DownloadButton`'s Advanced Options size estimate needs
    /// the same classification for a source it hasn't downloaded yet.
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

    /// Appends to `pendingQueue` and tries to admit it. Non-`private` so tests
    /// can drive the queue without the full async `enqueue`.
    func queueVideoDownload(itemID: String) {
        guard !pendingQueue.contains(itemID) else { return }
        pendingQueue.append(itemID)
        admitQueuedDownloadsIfPossible()
    }

    /// Starts as many queued downloads as `maxConcurrentDownloads` allows, in
    /// FIFO order. Called when the queue gains an entry or a slot frees. Skips
    /// a popped row that is no longer `.queued` with a URL.
    private func admitQueuedDownloadsIfPossible(respectingLimit: Bool = true) {
        // Once after the loop, not per row: several slots freeing at once
        // shouldn't mean several SwiftData round-trips.
        var admittedAny = false
        while !respectingLimit || canStartAnotherDownload {
            guard !pendingQueue.isEmpty else { break }
            let itemID = pendingQueue.removeFirst()
            guard let row = store.item(itemID: itemID), row.status == .queued,
                  let urlString = row.pendingDownloadURLString, let url = URL(string: urlString)
            else { continue }
            row.status = .downloading
            // Kept for as long as the row is downloading, so
            // `resolveFailedDownload` can re-arm after a transport failure
            // without re-running `enqueue`'s artwork and sidecar prep. Both
            // readers gate on `status == .queued`.
            admittedAny = true
            // Reserved before either starter runs, so a no-op
            // `startVideoDownloadOverride` still counts against the limit.
            activeItemIDs.insert(itemID)
            if let startVideoDownloadOverride {
                startVideoDownloadOverride(itemID, url, row.videoFilePath)
            } else {
                startVideoDownload(itemID: itemID, url: url, relativePath: row.videoFilePath)
            }
            // Only now does a server-side transcode job exist to ping and read
            // (see `pendingPollStarters`). Absent for a row resumed after a
            // relaunch, which has no client this early.
            pendingPollStarters.removeValue(forKey: itemID)?()
        }
        if admittedAny { store.save() }
    }

    /// Starts every remaining queued download, ignoring
    /// `maxConcurrentDownloads`. Called when the scene leaves the foreground.
    ///
    /// iOS forces any background-session task created while the app is not in
    /// the foreground to be discretionary and defers it indefinitely (see
    /// DOWNLOADS.md), so a queue cannot advance once suspended. The tasks must
    /// already exist for the rest of a season to complete unattended.
    ///
    /// The concurrency limit is abandoned rather than preserved because it
    /// cannot be honored: at suspension `nsurlsessiond` takes ownership of
    /// every created task and schedules them itself, measured at up to 11 at
    /// once against a configured limit of 2. The limit still applies while the
    /// app is open, which the Downloads settings footer states.
    func releaseQueueForBackgroundExecution() {
        guard !pendingQueue.isEmpty else { return }
        admitQueuedDownloadsIfPossible(respectingLimit: false)
    }

    /// `nil` means Unlimited and always allows another.
    private var canStartAnotherDownload: Bool {
        guard let limit = preferences.maxConcurrentDownloads else { return true }
        return activeItemIDs.count < limit
    }

    /// Rebuilds `pendingQueue` from `.queued` rows surviving to a fresh launch;
    /// unlike a started download, they have no background task to reattach to.
    /// Ordered by `createdAt` to preserve tap order. Must run after
    /// `adoptInFlightDownloads`, which reserves the in-flight rows' slots.
    private func resumePendingQueue() {
        let queuedRows = store.allItems()
            .filter { $0.status == .queued && $0.pendingDownloadURLString != nil }
            .sorted { $0.createdAt < $1.createdAt }
        pendingQueue = queuedRows.map(\.itemID)
        admitQueuedDownloadsIfPossible()
    }

    /// Re-adopts every row still `.downloading` at launch against the
    /// background session's live task list.
    ///
    /// `handleBackgroundSessionEvents` runs only when the OS relaunches the app
    /// to deliver a finished session's events. An ordinary relaunch — force-quit
    /// and reopen, or a jetsam kill — never goes through it, leaving a
    /// `.downloading` row stuck at "Downloading…" forever.
    ///
    /// Slots are reserved synchronously, before the async sweep returns, which
    /// is exact because `finishAdopting` resolves every stale row in one pass.
    private func adoptInFlightDownloads() {
        let downloadingRows = store.allItems().filter { $0.status == .downloading }
        guard !downloadingRows.isEmpty else { return }
        for row in downloadingRows {
            activeItemIDs.insert(row.itemID)
        }
        if let reattachVideoDownloadOverride {
            // Test seam: no session to sweep, so the override stands in for
            // every one of these still being live.
            downloadingRows.forEach { reattachVideoDownloadOverride($0.itemID) }
            return
        }
        // Captured and passed through rather than re-read when the sweep
        // returns: `resumePendingQueue()` can start fresh downloads before the
        // callback fires, and those postdate `getAllTasks`' snapshot.
        // Reconciling against the live set would resolve a just-started
        // download as one whose transfer had vanished.
        let reserved = Set(downloadingRows.map(\.itemID))
        backgroundSession.getAllTasks { [weak self] tasks in
            Task { @MainActor in
                self?.finishAdopting(tasks: tasks, reserved: reserved)
            }
        }
    }

    /// Reconciles the session's task list against the store in one pass.
    private func finishAdopting(tasks: [URLSessionTask], reserved: Set<String>) {
        var adopted: Set<String> = []
        for task in tasks {
            guard let downloadTask = task as? URLSessionDownloadTask else { continue }
            guard let itemID = adoptedItemID(for: downloadTask),
                  let row = store.item(itemID: itemID), row.status == .downloading
            else {
                // A transfer whose row is gone: the transfer-layer counterpart
                // of `DownloadFileStore.deleteOrphanedItemDirectories`, so a
                // deleted item can't keep writing into a directory that sweep
                // will later remove.
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

    /// The configuration behind `backgroundSession`. Sets the timeouts
    /// explicitly, since a bare `.background(withIdentifier:)` configuration
    /// falls back to a system default measured in days, and
    /// `waitsForConnectivity` so a transfer with no network defers.
    ///
    /// Cellular is permitted here and gated per request instead: a session
    /// living for the whole process can't have its configuration rewritten when
    /// the Wi-Fi Only toggle flips, but a request flag is re-read every time.
    ///
    /// Non-`private` so tests can assert on it directly.
    static func makeBackgroundConfiguration() -> URLSessionConfiguration {
        #if DEBUG
        // A background configuration transfers in a separate system daemon,
        // out of `URLProtocol`'s reach — an in-process stub is never consulted
        // and the download hits the real network. UI tests therefore drop to a
        // default in-process configuration.
        //
        // A real behavioural divergence: it does not reproduce backgrounding,
        // suspension or OS-relaunch resumption, so UI coverage stops at "bytes
        // land and the row settles" and those stay device-only checks.
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

    /// Starts one transfer on the shared session. `taskDescription` carries the
    /// itemID, which is how `DownloadTaskRouter` routes callbacks back to a row
    /// after an OS relaunch, so it must be set before `resume()`.
    private func startVideoDownload(itemID: String, url: URL, relativePath: String) {
        let task = backgroundSession.downloadTask(
            with: Self.makeFetchRequest(url: url, allowsCellularAccess: !preferences.wifiOnly)
        )
        task.taskDescription = itemID
        downloadTasks[itemID] = task
        task.resume()
    }

    /// Re-attaches the background session so the OS can finish delivering
    /// callbacks for transfers that completed while the app was suspended, then
    /// answers UIKit's completion handler. Reached from `AppDelegate` via
    /// `NotificationCenter` (see `init`).
    ///
    /// Answering is not optional: the OS treats an unanswered handler as the
    /// app still being busy and reclaims its background time more aggressively.
    /// The remaining hole — events delivered before the handler was stashed —
    /// is closed by the empty-task-list check and the timed backstop below.
    private func handleBackgroundSessionEvents(identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == Self.backgroundSessionIdentifier else {
            // A per-item scheme identifier: nothing left to route callbacks to,
            // but the handler must still be answered and the session reclaimed.
            if identifier.hasPrefix(Self.legacyPerItemSessionIdentifierPrefix) {
                // A background configuration requires a delegate. The router
                // ignores these tasks, which carry no `taskDescription`.
                URLSession(configuration: .background(withIdentifier: identifier), delegate: router, delegateQueue: nil)
                    .invalidateAndCancel()
            }
            completionHandler()
            return
        }
        // Answer any previous handler before replacing it.
        backgroundCompletionHandler?()
        backgroundCompletionHandler = completionHandler
        // Touching the session re-attaches it and starts callbacks flowing.
        backgroundSession.getAllTasks { [weak self] tasks in
            Task { @MainActor in
                guard let self else { return }
                // Nothing in flight means every event landed before this
                // handler was stashed, so `urlSessionDidFinishEvents` will
                // never arrive to answer it.
                if tasks.isEmpty { self.answerBackgroundCompletionHandler() }
            }
        }
        // Backstop, well inside the ~30s the OS allows: answering early beats
        // leaving it unanswered on an unanticipated path.
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

    /// Reclaims background sessions left live in `nsurlsessiond` by builds
    /// predating the single-session change, whose tasks have nothing left to
    /// route to. Runs once.
    ///
    /// Scoped to `.downloading` rows: creating a background session is an XPC
    /// round trip and this runs on the main actor during `init`, so sweeping a
    /// whole library would be exactly the launch-time churn this removes. Other
    /// statuses were already invalidated by the old completion path, and each
    /// row touched here is resolved by `finishAdopting` in the same launch.
    /// Removable once a few releases have shipped.
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
        // Re-queried per tick rather than captured: a dictionary lookup against
        // an in-memory SwiftData row, not a fetch.
        let estimatedTotalBytes = store.item(itemID: itemID)?.estimatedTotalBytes ?? 0
        let total = expected > 0 ? expected : estimatedTotalBytes
        // Merged, not overwritten: a fresh `DownloadProgress()` would discard
        // the `transcodeCompletionPercentage` that
        // `startTranscodeProgressPolling` sets, on every byte chunk.
        var progress = activeDownloads[itemID] ?? DownloadProgress(bytesDownloaded: 0, totalBytesExpected: 0)
        progress.bytesDownloaded = downloaded
        progress.totalBytesExpected = total
        activeDownloads[itemID] = progress
    }

    private func handleDownloadCompletion(itemID: String, result: Result<Void, Error>) {
        // `didFinishDownloadingTo` and `didCompleteWithError` are not mutually
        // exclusive: a task can deliver its file and then complete with an
        // error. Landing second, the failure would win the status write,
        // flipping a `.completed` download to `.failed`, free the concurrency
        // slot twice, and admit one row past the limit. This also drops
        // callbacks for an item deleted mid-transfer, since `delete(itemID:)`
        // removes the id here. `DownloadTaskRouter`'s own guard is independent
        // and fails in a different direction.
        guard activeItemIDs.remove(itemID) != nil else { return }
        activeDownloads[itemID] = nil
        downloadTasks[itemID] = nil
        // A slot freed, so admit the next entry whether or not this row still
        // exists below. No session teardown: `backgroundSession` outlives every
        // individual transfer.
        admitQueuedDownloadsIfPossible()
        switch result {
        case .success:
            stopTranscodeProgressPolling(itemID: itemID)
            automaticRetryAttempts[itemID] = nil
            // A `Task` because validation awaits an `AVURLAsset` duration load,
            // which this synchronous callback can't. The queue cleanup above
            // already ran, so the next download doesn't wait on it.
            let relativePath = DownloadFileStore.videoRelativePath(itemID: itemID)
            Task { @MainActor in
                await self.finalizeCompletedDownload(itemID: itemID, relativePath: relativePath)
            }
        case .failure(let error):
            resolveFailedDownload(itemID: itemID, error: error)
        }
    }

    // MARK: - Transient transport failures

    /// Whether a transfer died for a reason that says nothing about whether it
    /// can succeed, making a re-arm better than a failed row.
    ///
    /// `.backgroundSessionWasDisconnected` (-997) is the case this exists for:
    /// the app's channel to `nsurlsessiond` went away, a fact about the daemon
    /// rather than the download. `.cancelled` (-999) is excluded — a force-quit
    /// or OS cancellation, where silently restarting a transcode is worse than
    /// reporting it — as is `DownloadTransferError.badStatus`, where the server
    /// answered and said no. Anything unrecognised stays a visible failure.
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

    /// Re-arms the transfer (transport failure with budget remaining) or
    /// settles the row as `.failed` with a written message.
    ///
    /// A re-arm re-submits the same URL, still carried by
    /// `pendingDownloadURLString`, so `enqueue`'s artwork and sidecar prep is
    /// not re-run. The poll loop keeps running across the backoff window
    /// because its keep-alive ping is what stops Jellyfin's 10-second kill
    /// timer destroying the job being reconnected to.
    ///
    /// Reusing the URL reuses its `PlaySessionId` and the server's transcode
    /// cache entry — wanted in the -997 case, where the client's channel broke
    /// but the encode did not, and safe otherwise because
    /// `finalizeCompletedDownload` rejects a short file. Minting a fresh
    /// `PlaySessionId` would need a live `JellyfinAPIClient`, which this type
    /// never stores; that escape hatch is `retry(itemID:client:)`.
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
            // A row surviving only to carry an unsynced watched or resume write
            // shouldn't be relabelled as a failed download.
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

    /// Runs once the transfer succeeded — good status, file moved into place by
    /// `DownloadTaskRouter` — but before trusting it as a complete download;
    /// `validationFailureReason` covers why that isn't automatic. A row deleted
    /// mid-transfer has nothing left to update.
    private func finalizeCompletedDownload(itemID: String, relativePath: String) async {
        guard let row = store.item(itemID: itemID) else { return }
        if let failureReason = await Self.validationFailureReason(relativePath: relativePath, expectedRuntimeTicks: row.runtimeTicks) {
            // Otherwise a `.failed` row still points at a real file, playable
            // up to where it stopped — which is what made the underlying bug
            // invisible.
            try? FileManager.default.removeItem(at: DownloadFileStore.url(forRelativePath: relativePath))
            row.status = .failed
            row.errorMessage = failureReason
        } else {
            row.status = .completed
            row.errorMessage = nil
        }
        store.save()
    }

    /// `nil` when the file's actual duration is close enough to
    /// `expectedRuntimeTicks`, the runtime recorded at enqueue; a user-facing
    /// reason otherwise.
    ///
    /// A transcode's HTTP response is chunked, with no `Content-Length`, and
    /// closes identically whether ffmpeg finished or crashed partway. A
    /// VideoToolbox `scale_vt` crash under concurrent load produced a valid,
    /// HTTP-200, playable four-minute MP4 for a 134-minute film, which
    /// `URLSessionDownloadTask` reported as a completed transfer.
    /// `DownloadTaskRouter`'s status check catches only an outright error
    /// response, not a stream that ends early while claiming success.
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

    /// The decision behind `validationFailureReason`, as a pure function so it
    /// is testable without `AVFoundation` or real files. Non-`private` so the
    /// test target can call it.
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

    /// How much of the expected runtime a file must contain to count as
    /// complete. Below 100% because keyframe and mux rounding can leave a good
    /// transcode a fraction of a second short of the source's `RunTimeTicks`.
    /// 95% clears that noise floor while still catching a truncated file, which
    /// in the observed failure held ~3% of its expected runtime.
    static let durationValidationMinimumFraction = 0.95

    // MARK: - Live transcode-progress polling

    /// Runs two jobs every `transcodeProgressPollInterval` for the life of one
    /// download's video transfer:
    ///
    /// 1. **Keep-alive ping** (`JellyfinAPIClient.pingDownloadTranscode`), for
    ///    every download including a stream copy, which is still a
    ///    `Progressive` job subject to the same kill timer. Jellyfin reads a
    ///    connection stall under concurrent-download CPU contention as the
    ///    client disconnecting and arms a 10-second kill timer; with nothing
    ///    refreshing it on the same `PlaySessionId`, the job dies and a
    ///    reconnect re-encodes from byte zero. Server logs showed three full
    ///    re-encodes of one 12-minute stretch, each ended by that timer.
    /// 2. **Live completion percentage** (see
    ///    `DownloadProgress.transcodeCompletionPercentage`), read from
    ///    `currentSession(deviceID:)` directly. Jellyfin never populates
    ///    `NowPlayingItem`/`PlayState.MediaSourceId` for a plain
    ///    transcode-stream request, so an item-matching filter would match
    ///    nothing. The device has only one session row, which means concurrent
    ///    downloads share one `TranscodingInfo`, clobbered by whichever job
    ///    reported last. Applying that to this item would be wrong rather than
    ///    imprecise, so it is trusted only while
    ///    `transcodeProgressPollTasks.count == 1`; otherwise every download
    ///    falls back to its own byte estimate.
    ///
    /// Takes `client` per call rather than storing one, since this manager
    /// outlives sign-in/sign-out (see `onRowMarkedForDeletion`). The trade-off
    /// is that a download reattached after a relaunch, before any client
    /// exists, gets neither ping nor percentage — leaving it unprotected
    /// against the kill timer, not merely without a display.
    ///
    /// A failed ping or poll is skipped rather than treated as an error.
    private func startTranscodeProgressPolling(itemID: String, playSessionId: String, client: JellyfinAPIClient) {
        transcodeProgressPollTasks[itemID]?.cancel()
        transcodeProgressPollTasks[itemID] = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.transcodeProgressPollInterval)
                guard !Task.isCancelled, let self else { return }
                try? await client.pingDownloadTranscode(playSessionId: playSessionId)
                guard var progress = self.activeDownloads[itemID] else { continue }

                // Trust the shared session's percentage only while this is the
                // sole transcoding download; otherwise it may be another item's.
                guard self.transcodeProgressPollTasks.count == 1 else {
                    // Without this, a value set while this was the only
                    // transcoding download freezes the moment a second starts:
                    // `fractionCompleted` prefers this field over the byte
                    // estimate, so the ring pins to a stale number while the
                    // byte count climbs underneath. Clearing it falls back to
                    // the byte estimate for as long as the ambiguity lasts.
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

    /// Also drops any staged starter: an item deleted while queued never ran
    /// its loop, but its closure would keep a `JellyfinAPIClient` alive for the
    /// life of this manager.
    private func stopTranscodeProgressPolling(itemID: String) {
        transcodeProgressPollTasks[itemID]?.cancel()
        transcodeProgressPollTasks[itemID] = nil
        pendingPollStarters[itemID] = nil
    }

    // MARK: - Delete

    /// Frees the video and subtitle files unconditionally, and each shared
    /// image field only when no other row references it. The row is removed
    /// immediately unless it carries an unsynced watched or resume write, in
    /// which case it survives as `markedForDeletion` until
    /// `DownloadSyncManager` completes that sync.
    ///
    /// Also cancels any in-flight transfer: a background task keeps running at
    /// the OS level after this manager drops its reference, and would go on
    /// writing bytes into a directory this deletion just removed.
    func delete(itemID: String) {
        guard let downloaded = store.item(itemID: itemID) else { return }
        DownloadFileStore.deleteItemFiles(itemID: itemID)
        // Fetched once for every check below, not re-fetched per check.
        let allItems = store.allItems()
        // Chapter stills share the content-addressed image pool with the four
        // fields above, so they need the same guarded unlink; a blind delete
        // would leak them on every deletion.
        let sharedImagePaths = [
            downloaded.posterImagePath, downloaded.backdropImagePath, downloaded.logoImagePath, downloaded.thumbImagePath
        ] + downloaded.chapters.map(\.imageRelativePath)
        for path in sharedImagePaths {
            DownloadFileStore.deleteImageIfUnreferenced(relativePath: path, excludingItemID: itemID, store: store, among: allItems)
        }
        // A non-nil `remove` means the transfer started, so gating on it keeps
        // this a no-op for a still-`.queued` row. Removing the id also makes
        // any later callback a no-op in `handleDownloadCompletion`, including
        // the `NSURLErrorCancelled` the cancel below provokes.
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
                // Covers the window between `init` and `finishAdopting`, where
                // a transfer adopted from a previous launch is live but not yet
                // in `downloadTasks`.
                backgroundSession.getAllTasks { tasks in
                    tasks.filter { $0.taskDescription == itemID }.forEach { $0.cancel() }
                }
            }
        }
        // Only meaningful for a row still waiting for a concurrency slot.
        pendingQueue.removeAll { $0 == itemID }

        if downloaded.pendingSync {
            downloaded.markedForDeletion = true
            store.save()
            // Nudges `DownloadSyncManager` rather than waiting for the next
            // scenePhase trigger.
            onRowMarkedForDeletion?()
        } else {
            store.delete(downloaded)
        }
        // The `activeItemIDs.remove` above freed a slot, so admit the next
        // entry now rather than leaving it `.queued` until an unrelated event.
        admitQueuedDownloadsIfPossible()
    }

    #if DEBUG
    // MARK: - Test seam (DownloadManagerTests only — see `startVideoDownloadOverride`)

    /// Frees a slot and admits the next queued item, mirroring the bookkeeping
    /// half of `handleDownloadCompletion`. Not routed through the success
    /// branch, which would run `finalizeCompletedDownload`'s `AVURLAsset` load
    /// against a file no unit test has written. Compiled out of Release.
    func test_simulateDownloadFinished(itemID: String) {
        guard activeItemIDs.remove(itemID) != nil else { return }
        activeDownloads[itemID] = nil
        downloadTasks[itemID] = nil
        stopTranscodeProgressPolling(itemID: itemID)
        automaticRetryAttempts[itemID] = nil
        admitQueuedDownloadsIfPossible()
    }

    /// Drives the failure half of `handleDownloadCompletion` — retry
    /// classification, budget and slot accounting — without a real transfer.
    /// Compiled out of Release.
    func test_simulateDownloadFailed(itemID: String, error: Error) {
        handleDownloadCompletion(itemID: itemID, result: .failure(error))
    }

    /// Running transcode poll loops, so a test can assert that a queued item
    /// starts none. Compiled out of Release.
    var test_activeTranscodePollCount: Int { transcodeProgressPollTasks.count }
    #endif
}

extension Notification.Name {
    static let dionysusHandleBackgroundURLSession = Notification.Name("dionysusHandleBackgroundURLSession")
}

/// Keys into the `userInfo` posted with `.dionysusHandleBackgroundURLSession`.
enum DionysusBackgroundURLSessionUserInfoKey {
    static let identifier = "identifier"
    static let completionHandler = "completionHandler"
}

/// Wraps UIKit's non-`@Sendable` background-session completion handler so it
/// can cross into `DownloadManager`'s `@MainActor` isolation through
/// `NotificationCenter`, which requires a `@Sendable` payload.
///
/// `@unchecked` is safe: the closure is invoked once, on the main thread —
/// UIKit posts it there and the observer is registered with `queue: .main`.
final class BackgroundSessionCompletionBox: @unchecked Sendable {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
}
