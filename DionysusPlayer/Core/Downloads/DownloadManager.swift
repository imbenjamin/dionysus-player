import Foundation
import Observation

/// Live progress for one in-flight download — what `DownloadsView`/
/// `DownloadButton` bind to. Deliberately not persisted to `DownloadedItem`
/// on every tick (that would mean a SwiftData write per `didWriteData`
/// callback, dozens of times a second) — this in-memory dictionary is the
/// UI's live source of truth, and the row's own `bytesDownloaded`/
/// `totalBytesExpected` fields are only updated once, at completion.
struct DownloadProgress: Equatable {
    var bytesDownloaded: Int64
    /// The server never reports a real `Content-Length` for this
    /// live-transcode stream (`Static=false` — see `JellyfinAPIClient
    /// .downloadStreamURL`; the output is sent as it's encoded, with no
    /// final size known up front), so this is normally `DownloadedItem
    /// .estimatedTotalBytes` — a bitrate/runtime-based estimate computed
    /// once at enqueue time — rather than anything the transfer itself
    /// reported. Only actually `<= 0` (unknown) when even that estimate
    /// couldn't be computed. See `makeVideoDownloadDelegate`'s `onProgress`
    /// closure for where the substitution happens.
    var totalBytesExpected: Int64

    var isTotalKnown: Bool { totalBytesExpected > 0 }

    /// `0` when `!isTotalKnown`. Clamped to `1` otherwise — `totalBytesExpected`
    /// is usually an *estimate* (see its own doc comment), and real encoder
    /// output commonly lands a bit above or below a target bitrate, so
    /// `bytesDownloaded` can end up exceeding it right near the end.
    var fractionCompleted: Double {
        guard isTotalKnown else { return 0 }
        return min(1, Double(bytesDownloaded) / Double(totalBytesExpected))
    }

    /// "Downloading… 42%" when the server reported a total size,
    /// "Downloading… 128 MB" (bytes transferred so far, the only number
    /// there is to show) when it didn't.
    var statusText: String {
        if isTotalKnown {
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

    var errorDescription: String? {
        switch self {
        case .missingMediaSource: return String(localized: "This item has no downloadable media source.")
        case .invalidDownloadURL: return String(localized: "Couldn't build a download URL for this item.")
        case .itemNoLongerAvailable: return String(localized: "This item is no longer available on the server.")
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

    /// Fired from `delete(itemID:)` right after a row survives as
    /// `markedForDeletion` — set once by `AppState` (the only place that
    /// can safely resolve a *live* `JellyfinAPIClient` for it) to nudge
    /// `DownloadSyncManager` immediately, rather than leaving that row to
    /// wait for the next scenePhase foreground/reconnect trigger, which
    /// might not come for a while (see `delete(itemID:)`'s own doc
    /// comment for the real "spinner stuck indefinitely" bug this fixes).
    /// A closure rather than a stored `client` property here specifically
    /// because `DownloadManager` (unlike `AppState.apiClient`) is created
    /// once and never recreated across sign-in/sign-out/server changes —
    /// storing a client directly would go stale the moment the user
    /// switches servers or signs out. `nil` is a safe, harmless no-op
    /// (matches `DownloadManagerTests`' own construction, which never sets
    /// this) — the row still clears on the next scenePhase trigger either
    /// way, just not immediately.
    var onRowMarkedForDeletion: (() -> Void)?

    /// Not `private` — the Downloads UI (`DownloadsViewModel`,
    /// `DownloadedAssetDetailView`, etc.) reads directly from this rather
    /// than going through a growing set of pass-through methods here; this
    /// type still owns every *write* path (`enqueue`/`delete`).
    let store: DownloadStore
    /// Every background session identifier this manager hands out is this
    /// prefix plus the itemID — deterministic and reversible, so a
    /// relaunch-triggered reattachment (`reattachBackgroundSession`) can
    /// recover which item a bare identifier string belongs to with no
    /// extra state of its own to keep in sync.
    private static let backgroundSessionIdentifierPrefix = "com.dionysus.downloads."
    /// Jellyfin transcode jobs need to warm up before they start streaming
    /// bytes back — kept as a single named constant, per an explicit
    /// requirement in the offline-downloads plan, so it's the obvious knob
    /// to raise later if 60s ever proves too tight.
    private static let downloadRequestTimeout: TimeInterval = 60
    /// A 4K transcode can run for a genuinely long time — this bounds the
    /// whole resource fetch, not just the initial warm-up
    /// (`downloadRequestTimeout` above).
    private static let downloadResourceTimeout: TimeInterval = 60 * 60 * 6
    /// How many trickplay tile-sheet JPEGs `downloadTrickplayTiles` fetches
    /// at once — bounded rather than fully unbounded (all sheets at once)
    /// to stay a well-behaved citizen of the same connection Jellyfin is
    /// also serving the (much larger, more important) video transcode over.
    private static let maxConcurrentTrickplaySheetDownloads = 4

    /// Delegates keyed by itemID — kept alive here for the download's
    /// lifetime since `URLSession` doesn't retain its own delegate. Also
    /// doubles as the "how many video downloads are actually running right
    /// now" count (`canStartAnotherDownload`) — a started background
    /// session always has one of these, a merely `.queued`-waiting-for-a-
    /// slot item never does.
    private var delegates: [String: DownloadSessionDelegate] = [:]
    /// Stashed by a background relaunch (`reattachBackgroundSession`),
    /// called once that session reports every queued callback delivered.
    private var backgroundCompletionHandlers: [String: () -> Void] = [:]
    /// Item IDs waiting for a concurrency slot (`DownloadPreferencesStore
    /// .maxConcurrentDownloads`), in the order they became ready to wait —
    /// FIFO, popped from the front by `admitQueuedDownloadsIfPossible`. Not
    /// the same thing as "every `.queued` row": an item can be `.queued` and
    /// not yet in here too, for the brief window `enqueue` spends fetching
    /// its subtitle sidecars before it's actually ready to queue for video.
    private var pendingQueue: [String] = []
    /// Live background `URLSession`s, keyed by itemID — kept alive here for
    /// the same reason `delegates` is (`URLSession` doesn't need to be
    /// retained for a background transfer to keep running at the OS level,
    /// but *this* manager needs a handle back to it so `delete(itemID:)` can
    /// actually cancel an in-flight one — see that method's own doc comment
    /// for the real bug this fixes). Populated by both `startVideoDownload`
    /// and `reattachBackgroundSession` (a relaunch-recovered session is just
    /// as cancellable as one started this launch), cleared alongside
    /// `delegates` on completion or cancellation.
    private var sessions: [String: URLSession] = [:]
    /// Item IDs `reattachInFlightDownloads`'s async liveness check has
    /// claimed but not yet resolved for — see that method's own doc
    /// comment for the real `-999` race this guards against between it and
    /// `reattachBackgroundSession`.
    private var reattachmentPending: Set<String> = []
    /// Injectable (same DI spirit as `store`) so `DownloadManagerTests` can
    /// drive `maxConcurrentDownloads` directly rather than mutating
    /// `UserDefaults.standard` for the duration of a test.
    private let preferences: DownloadPreferencesStore
    /// Test-only DI seam (`nil` — the default — always uses the real
    /// `startVideoDownload`, a real background `URLSessionDownloadTask`):
    /// lets `DownloadManagerTests` verify `admitQueuedDownloadsIfPossible`'s
    /// own FIFO/concurrency-limit bookkeeping without hitting the network
    /// or creating a real background session, same "don't unit-test the
    /// real download engine" boundary this file's tests already document.
    /// Passed into `init` (rather than assigned after) so it's in place
    /// before `resumePendingQueue()` runs, which can itself admit
    /// downloads immediately.
    private let startVideoDownloadOverride: ((String, URL, String) -> Void)?
    /// Test-only DI seam, same spirit as `startVideoDownloadOverride`: when
    /// set, `delete(itemID:)` calls this instead of touching `sessions`
    /// directly, so `DownloadManagerTests` can assert a cancellation was
    /// requested for a given itemID without a real background session to
    /// invalidate.
    private let cancelVideoDownloadOverride: ((String) -> Void)?
    /// Test-only DI seam, same spirit as `startVideoDownloadOverride`/
    /// `cancelVideoDownloadOverride`: when set, `reattachInFlightDownloads`
    /// calls this instead of creating a real background `URLSession`, so
    /// `DownloadManagerTests` can assert a `.downloading` row got reattached
    /// at launch without needing a real background session (this codebase's
    /// established "don't unit-test the real download engine" boundary).
    private let reattachVideoDownloadOverride: ((String) -> Void)?

    init(
        store: DownloadStore,
        preferences: DownloadPreferencesStore = DownloadPreferencesStore(),
        startVideoDownloadOverride: ((String, URL, String) -> Void)? = nil,
        cancelVideoDownloadOverride: ((String) -> Void)? = nil,
        reattachVideoDownloadOverride: ((String) -> Void)? = nil
    ) {
        self.store = store
        self.preferences = preferences
        self.startVideoDownloadOverride = startVideoDownloadOverride
        self.cancelVideoDownloadOverride = cancelVideoDownloadOverride
        self.reattachVideoDownloadOverride = reattachVideoDownloadOverride
        super.init()
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
                self?.reattachBackgroundSession(identifier: identifier, completionHandler: box.handler)
            }
        }
        // See `DownloadFileStore.deleteOrphanedItemDirectories`'s own doc
        // comment for the bug this sweeps up after — cheap (unlinking
        // directory entries, not proportional to file size) and safe to run
        // unconditionally on every launch.
        DownloadFileStore.deleteOrphanedItemDirectories(knownItemIDs: Set(store.allItems().map(\.itemID)))
        // `reattachInFlightDownloads` first, not after — for the test-seam
        // path (`reattachVideoDownloadOverride`, still synchronous) this
        // reserves a concurrency slot before `resumePendingQueue`'s own
        // admission pass runs, so `canStartAnotherDownload` sees the
        // correct count (a real bug, confirmed by a failing test while
        // writing this fix: the reverse order let `resumePendingQueue`
        // admit a fresh `.queued` row past the configured limit). The real
        // (non-test-seam) path can't offer that same synchronous guarantee
        // any more — see `reattachInFlightDownloads`'s own doc comment for
        // why it now verifies liveness asynchronously, and the small,
        // self-correcting slot-count overshoot that tradeoff accepts.
        reattachInFlightDownloads()
        resumePendingQueue()
    }

    convenience override init() {
        self.init(store: .makeDefault())
    }

    // MARK: - Enqueue

    /// Flow: build the capped transcode URL → capture the metadata/segments/
    /// artwork snapshot → create the `DownloadedItem` row (`.queued`) →
    /// download text-based subtitle sidecars inline (small, quick) → hand
    /// the video request to `queueVideoDownload`, which starts it on a
    /// background `URLSessionDownloadTask` immediately if there's a free
    /// concurrency slot (`DownloadPreferencesStore.maxConcurrentDownloads`)
    /// or leaves it `.queued` to wait for one otherwise. `mediaSource`/
    /// `audioTrack`/`subtitleTracks` are whatever the caller
    /// (`DownloadButton`) already resolved via its own `playbackInfo` fetch
    /// and prompts — this doesn't
    /// re-fetch or re-prompt.
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
        guard let mediaSourceID = mediaSource.id else { throw DownloadError.missingMediaSource }
        // A redownload of an item that already has a row (any status —
        // `.completed`, `.failed`, or an abandoned `.queued`/`.downloading`
        // one from an earlier attempt) must start from a clean slate rather
        // than `store.insert(downloaded)` below relying on SwiftData's own
        // `@Attribute(.unique)`-conflict merge to reconcile a brand-new
        // `DownloadedItem` against whatever's already persisted for this
        // `itemID` — a real bug found live (2026-08-20): redownloading
        // Rushmore at a higher quality after an earlier lower-quality
        // attempt showed the *new* quality in the stored metadata (the
        // Details tab reads straight off the row) while actual playback
        // still read the *old* video file untouched on disk — exactly the
        // kind of split-brain state an implicit partial merge risks,
        // rather than a clean insert. `delete(itemID:)` already knows how
        // to tear an existing row/its files down correctly (cancelling an
        // in-flight session, freeing files) — reuse it here instead of
        // trusting `insert` alone to reconcile a duplicate key.
        //
        // Not fully bulletproof: a row with `pendingSync == true` survives
        // `delete(itemID:)` as a `markedForDeletion` row purely to carry
        // its unsynced watched/resume write (see that method's own doc
        // comment), so `store.item(itemID:)` could still find *something*
        // immediately afterward in that specific case — rare enough
        // (redownloading the same item within the same short window as an
        // unsynced pending delete) that it's a known follow-up rather than
        // solved here.
        if store.item(itemID: item.id) != nil {
            delete(itemID: item.id)
        }
        let streams = mediaSource.mediaStreams ?? []
        let videoStream = streams.first { $0.type == "Video" }
        let isSourceHDR = Self.isHDR(videoStream)

        guard let downloadURL = await client.downloadStreamURL(
            itemID: item.id, mediaSourceID: mediaSourceID, audioStreamIndex: audioTrack?.index,
            resolution: resolution, preset: preset, isSourceHDR: isSourceHDR,
            sourceWidth: videoStream?.width, sourceHeight: videoStream?.height, sourceBitrate: mediaSource.bitrate
        ) else { throw DownloadError.invalidDownloadURL }

        let target = DownloadTranscodeCalculator.target(
            resolution: resolution, preset: preset, isSourceHDR: isSourceHDR,
            sourceWidth: videoStream?.width, sourceHeight: videoStream?.height, sourceBitrate: mediaSource.bitrate
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
            // NOT `isSourceHDR` — permanently `false`, not a placeholder
            // pending future work. Confirmed live and root-caused
            // (2026-08-19 through 2026-08-20, "Rushmore"/"Ex Machina"/
            // "Dunkirk"/others): a download always requests a transcode
            // (resolution/bitrate capping), and Jellyfin's transcoder does
            // not support HDR-to-HDR output at all — any source that needs
            // re-encoding is tone-mapped to SDR unconditionally, regardless
            // of `VideoProfile`/`hevc-*` query params, `DeviceProfile`
            // negotiation, or server hardware/tone-mapping settings. Tried,
            // in order: a plain `VideoProfile=main10` query param (didn't
            // work) — a fully negotiated `/PlaybackInfo` request with a real
            // `DeviceProfile` declaring HDR10/HDR10Plus/HLG support (server
            // still tone-mapped, and using the negotiated URL live broke
            // downloads outright via its `PlaySessionId` session-liveness
            // requirement) — the exact `hevc-profile`/`hevc-videobitdepth`/
            // `hevc-rangetype`/`hevc-level`/`RequireAvc` params Jellyfin's
            // own negotiation suggested, copied faithfully onto the
            // hand-built URL (still tone-mapped). Confirmed straight from
            // Jellyfin's own docs: "the source video ... will need to be
            // tone-mapped to SDR when transcoding, as Jellyfin currently
            // doesn't support HDR to HDR tone-mapping, or passing through
            // HDR metadata" (https://jellyfin.org/docs/general/post-install/transcoding/).
            // The only way to actually preserve HDR would be a stream-copy
            // (no re-encode) download path with no resolution/bitrate cap —
            // a distinct, larger feature, not attempted here.
            isHDR: false,
            selectedAudioTrackIndex: audioTrack?.index,
            selectedAudioTrackTitle: audioTrack?.displayTitle,
            videoFilePath: DownloadFileStore.videoRelativePath(itemID: item.id),
            skippedSubtitleTracks: subtitleTracks
                .filter { JellyfinAPIClient.isImageBasedSubtitleCodec($0.codec) }
                .map { $0.displayTitle ?? String(localized: "Track \($0.index + 1)") },
            // Not yet `.downloading` — the video task doesn't actually
            // start until `queueVideoDownload` below admits it past
            // `DownloadPreferencesStore.maxConcurrentDownloads`, which may
            // not happen right away. `pendingDownloadURLString` is what
            // lets that later admission (possibly after an app relaunch —
            // see `resumePendingQueue`) find its way back to this exact URL.
            status: .queued,
            pendingDownloadURLString: downloadURL.absoluteString,
            metadata: metadata
            // posterImagePath/backdropImagePath/logoImagePath/thumbImagePath/
            // segments/trickplayInfo deliberately left at their `nil`/`[]`
            // defaults here — see the fetch-and-backfill block just below
            // for why.
        )
        // Inserted *before* the poster/backdrop/logo/thumb/segments/trickplay
        // fetches, not after — a real bug found live (2026-08-21): this used
        // to build the full `downloaded` row (artwork included) only once
        // all of those network calls had already finished, so no row
        // existed yet for `DownloadButton`/`SeasonDownloadButton`'s
        // `isPreparing`/`isBusy` checks to key off. Against a "cold" Jellyfin
        // server (spun-down disks) those requests can each take several
        // seconds, during which the button had nothing to show but its
        // plain idle icon — reading exactly like the tap hadn't registered.
        // Inserting the row immediately (with placeholder empty artwork)
        // makes the button's spinner/progress state appear the instant this
        // method starts working, regardless of how slow the artwork fetches
        // below turn out to be; the row's artwork fields are backfilled
        // in-place once they resolve.
        store.insert(downloaded)

        let images = await client.makeImageURLBuilder()
        // Poster/backdrop/logo/thumb/segments/trickplay are all mutually
        // independent (none depends on another's result) — a real
        // inefficiency, found in a 2026-08-20 branch review: these used to
        // be awaited one after another, needlessly delaying the point at
        // which the actual video transfer (the much larger, more important
        // request) gets admitted to the download queue at all. Fetched
        // concurrently instead.
        async let posterPathTask = downloadImageIfNeeded(sourceItemID: item.id, imageType: "Primary", tag: item.dto.imageTags?["Primary"], maxWidth: 500, images: images)
        // Backdrop/logo: own image if present, else the nearest ancestor's
        // (same fallback `MediaItem.backdropImageURL`/`logoImageURL` apply
        // live) — see `resolveBackdropPath`/`resolveLogoPath` below.
        async let backdropPathTask = resolveBackdropPath(for: item, images: images)
        async let logoPathTask = resolveLogoPath(for: item, images: images)
        async let thumbPathTask = downloadImageIfNeeded(sourceItemID: item.id, imageType: "Thumb", tag: item.dto.imageTags?["Thumb"], maxWidth: 500, images: images)
        async let segmentDTOsTask = (try? await client.mediaSegments(itemID: item.id)) ?? []
        async let trickplayInfoTask = downloadTrickplayTiles(itemID: item.id, mediaSourceID: mediaSourceID, client: client, userID: userID, images: images)

        let (posterPath, backdropPath, logoPath, thumbPath, segmentDTOs, trickplayInfo) = await (
            posterPathTask, backdropPathTask, logoPathTask, thumbPathTask, segmentDTOsTask, trickplayInfoTask
        )

        downloaded.posterImagePath = posterPath
        downloaded.backdropImagePath = backdropPath
        downloaded.logoImagePath = logoPath
        downloaded.thumbImagePath = thumbPath
        downloaded.segments = segmentDTOs.compactMap { dto in
            guard let kind = Self.downloadedSegmentKind(from: dto.type) else { return nil }
            return DownloadedSegment(kind: kind, startSeconds: Double(dto.startTicks) / 10_000_000, endSeconds: Double(dto.endTicks) / 10_000_000)
        }
        downloaded.trickplayInfo = trickplayInfo
        downloaded.subtitleFiles = await downloadSubtitles(
            itemID: item.id, mediaSourceID: mediaSourceID, tracks: subtitleTracks, client: client
        )
        store.save()

        queueVideoDownload(itemID: item.id)
    }

    /// Re-attempts a `.failed` download using the exact same resolution/
    /// quality/audio-track choice as the original attempt — no
    /// re-prompting (unlike a fresh `DownloadButton` tap), since those
    /// were already explicit user choices the first time around. Added
    /// per direct feedback (2026-08-20): a failed download (most commonly
    /// confirmed live from force-quitting the app mid-transfer — see
    /// `friendlyDownloadFailureMessage`'s own doc comment) used to require
    /// deleting the row and re-finding/re-downloading the item from its
    /// live page from scratch; this lets the failed row's own detail page
    /// do it in one tap instead.
    ///
    /// Needs a live `client` — the offline Downloads pages this is called
    /// from are deliberately usable with no session at all (see
    /// `AppRouteDestinationView`'s own doc comment), so retry itself has
    /// to stay conditional on one actually being available; callers
    /// should hide/disable whatever triggers this when there isn't one.
    /// A no-op (not an error) if the row isn't actually `.failed` — a
    /// stray double-tap racing the button's own disabled state shouldn't
    /// re-enqueue a download that's already progressing.
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
        for stream in tracks where !JellyfinAPIClient.isImageBasedSubtitleCodec(stream.codec) {
            guard let url = await client.subtitleURL(itemID: itemID, mediaSourceID: mediaSourceID, streamIndex: stream.index, codec: stream.codec) else { continue }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
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
    /// instead of re-fetching a duplicate. `tag == nil` (the item has no
    /// image of this type at all) skips entirely, returning `nil`.
    /// A missing `tag` does **not** mean "skip this image" — confirmed
    /// live (2026-08-19): an episode routinely has no `imageTags["Primary"]`
    /// entry at all, yet its live `/Items/{id}/Images/Primary` route still
    /// serves a real still frame (the same content `MediaItem
    /// .primaryImageURL` fetches live, unconditionally, for exactly this
    /// reason). Skipping the fetch whenever `tag` was `nil` — the original
    /// version of this method — silently left episode downloads with no
    /// poster/backdrop at all. A `nil` tag instead falls back to a fixed
    /// placeholder identity (`"untagged"`) in the shared pool's filename —
    /// stable per item, just unable to detect a later image *change* on
    /// the server the way a real tag would, which is an acceptable
    /// trade-off for something that's only ever a cache key.
    ///
    /// Since this now *always* attempts the fetch, it also has to check
    /// the HTTP status explicitly — `URLSession.data(from:)` doesn't throw
    /// on a 404, so an item that genuinely has nothing at this route would
    /// otherwise silently write Jellyfin's HTML/JSON error body to disk as
    /// if it were image data.
    private func downloadImageIfNeeded(sourceItemID: String, imageType: String, tag: String?, maxWidth: Int, images: ImageURLBuilder) async -> String? {
        let identityTag = tag ?? "untagged"
        let relativePath = DownloadFileStore.imageRelativePath(sourceItemID: sourceItemID, imageType: imageType, tag: identityTag)
        if DownloadFileStore.imageAlreadyExists(sourceItemID: sourceItemID, imageType: imageType, tag: identityTag) {
            return relativePath
        }
        guard let url = images.url(itemID: sourceItemID, imageType: imageType, tag: tag, maxWidth: maxWidth) else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
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

    /// Fetches this item's trickplay track (if the server has scanned one)
    /// and every one of its tile-sheet JPEGs, so `OfflineTrickplayThumbnailProvider`
    /// has something to read during offline scrubbing — the offline
    /// counterpart to `TrickplayThumbnailProvider`'s live on-demand fetch.
    /// Entirely best-effort, same spirit as `mediaSegments` just above:
    /// `item`'s own DTO (whatever the caller's detail-page view model
    /// already had in hand) doesn't carry `Trickplay` — only
    /// `PlayerViewModel.start()`'s own item fetch requests that field, see
    /// `JellyfinAPIClient.detailFieldsWithTrickplay`'s doc comment — so this
    /// re-fetches the item with that field explicitly rather than relying
    /// on what's already loaded. Returns `nil` (no download attempted, no
    /// row poisoned by a partial one) whenever the item has no trickplay
    /// track at all, or the fetch to *learn* that fails; once a track is
    /// found, an individual sheet failing is non-fatal — same "this is a
    /// nice-to-have, not core to the download" tolerance `downloadSubtitles`
    /// applies to a single subtitle track — since a missing sheet just
    /// means `OfflineTrickplayThumbnailProvider` returns `nil` for whatever
    /// seconds land on it, no different from scrubbing past the end of a
    /// track Jellyfin never generated.
    private func downloadTrickplayTiles(
        itemID: String, mediaSourceID: String, client: JellyfinAPIClient, userID: String, images: ImageURLBuilder
    ) async -> TrickplayInfo? {
        guard let dto = try? await client.item(userID: userID, itemID: itemID, fields: JellyfinAPIClient.detailFieldsWithTrickplay),
              let info = TrickplayMath.bestInfo(from: dto.trickplay, mediaSourceID: mediaSourceID)
        else { return nil }

        let sheetCount = TrickplayMath.sheetCount(for: info)
        guard sheetCount > 0 else { return nil }
        // Concurrent, bounded to `maxConcurrentTrickplaySheetDownloads` —
        // every sheet index is independent (no shared state, no ordering
        // requirement; `OfflineTrickplayThumbnailProvider` reads them back
        // individually by index later), but this used to await each sheet's
        // full network round-trip before starting the next, serializing a
        // typical movie's several-to-a-dozen-plus sheets into `enqueue()`'s
        // critical path for no reason.
        await withTaskGroup(of: Void.self) { group in
            for sheetIndex in 0..<sheetCount {
                if sheetIndex >= Self.maxConcurrentTrickplaySheetDownloads {
                    _ = await group.next()
                }
                group.addTask {
                    guard let url = images.trickplayTileURL(itemID: itemID, width: info.width, sheetIndex: sheetIndex) else { return }
                    do {
                        let (data, response) = try await URLSession.shared.data(from: url)
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

    /// `error.localizedDescription` alone surfaces a raw system string for
    /// the single most common real-world failure — "The operation couldn't
    /// be completed. (NSURLErrorDomain error -999.)" — confirmed live
    /// (2026-08-20): force-quitting the app via the App Switcher (swipe-up)
    /// cancels its background `URLSession` transfers by design (documented
    /// iOS behavior — a force-quit is treated as an explicit "kill
    /// everything" signal, distinct from the OS suspending or killing a
    /// backgrounded app under memory pressure, which *does* preserve
    /// background transfers and *is* what `reattachInFlightDownloads`
    /// recovers). `NSURLErrorCancelled` (-999) on reattachment reflects
    /// that real, unrecoverable cancellation, not a bug to fix — but a raw
    /// error code is still a bad thing to show the user for it.
    private static func friendlyDownloadFailureMessage(for error: Error) -> String {
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return String(localized: "The download was interrupted and couldn't continue. Try downloading again.")
        }
        return error.localizedDescription
    }

    private static func isHDR(_ videoStream: MediaStream?) -> Bool {
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

    /// Appends to `pendingQueue` (a no-op if it's already there — guards
    /// against a stray double-call, not expected in practice) and
    /// immediately tries to admit it, same as every other slot-freeing
    /// event below. Not `private` — `enqueue` is its only production call
    /// site, but `DownloadManagerTests` calls this directly too, to drive
    /// the queue without going through the full async `enqueue` flow.
    func queueVideoDownload(itemID: String) {
        guard !pendingQueue.contains(itemID) else { return }
        pendingQueue.append(itemID)
        admitQueuedDownloadsIfPossible()
    }

    /// Starts as many queued video downloads as `DownloadPreferencesStore
    /// .maxConcurrentDownloads` currently allows, strictly in FIFO order —
    /// called whenever the queue gains an entry (`queueVideoDownload`) or a
    /// slot frees up (a download finishing, in `makeVideoDownloadDelegate`'s
    /// `onCompletion`). A row popped here that's no longer actually
    /// `.queued` with a URL to start (deleted, or somehow already started)
    /// is silently skipped rather than retried — nothing else would have
    /// left it in this list in that state.
    private func admitQueuedDownloadsIfPossible() {
        // Saved once, after the loop, not once per admitted row — several
        // slots can free up/admit at once (a full pending queue at launch,
        // or several downloads finishing close together), and each row's
        // `.downloading` transition doesn't need its own round-trip to
        // SwiftData's context.
        var admittedAny = false
        while canStartAnotherDownload {
            guard !pendingQueue.isEmpty else { break }
            let itemID = pendingQueue.removeFirst()
            guard let row = store.item(itemID: itemID), row.status == .queued,
                  let urlString = row.pendingDownloadURLString, let url = URL(string: urlString)
            else { continue }
            row.status = .downloading
            row.pendingDownloadURLString = nil
            admittedAny = true
            // Reserve the slot up front, before either starter below runs
            // — `startVideoDownload` immediately overwrites this with the
            // real delegate; `startVideoDownloadOverride` (tests only)
            // leaves this placeholder in place, which is all
            // `canStartAnotherDownload` needs to count the slot as
            // occupied without the override having to call back into any
            // of this type's private state itself.
            delegates[itemID] = DownloadSessionDelegate(
                destinationRelativePath: row.videoFilePath, onProgress: { _, _ in }, onCompletion: { _ in }, onFinishedEvents: {}
            )
            if let startVideoDownloadOverride {
                startVideoDownloadOverride(itemID, url, row.videoFilePath)
            } else {
                startVideoDownload(itemID: itemID, url: url, relativePath: row.videoFilePath)
            }
        }
        if admittedAny { store.save() }
    }

    /// `delegates.count` is exactly "how many video downloads are actually
    /// transferring right now" (see that property's own doc comment) —
    /// `nil` (Unlimited) always allows another.
    private var canStartAnotherDownload: Bool {
        guard let limit = preferences.maxConcurrentDownloads else { return true }
        return delegates.count < limit
    }

    /// Rebuilds `pendingQueue` from whatever `.queued` rows survived to a
    /// fresh launch — a row still waiting for a concurrency slot when the
    /// app was last backgrounded/terminated has no in-memory queue entry to
    /// resume from otherwise (unlike an already-*started* download, which
    /// survives via `reattachBackgroundSession`/`reattachInFlightDownloads`'s
    /// background `URLSession` reattachment): without this it would sit at
    /// `.queued` forever with nothing left to ever admit it. Ordered by
    /// `createdAt` so a relaunch preserves the same tap order the queue
    /// already promised within one session. Called once, from `init`,
    /// **after** `reattachInFlightDownloads` — see that method's own doc
    /// comment for why the order matters (this method's own admission pass
    /// needs already-`.downloading` rows' concurrency slots reserved
    /// first).
    private func resumePendingQueue() {
        let queuedRows = store.allItems()
            .filter { $0.status == .queued && $0.pendingDownloadURLString != nil }
            .sorted { $0.createdAt < $1.createdAt }
        pendingQueue = queuedRows.map(\.itemID)
        admitQueuedDownloadsIfPossible()
    }

    /// Recreates a background `URLSession` for every row still
    /// `.downloading` at launch — a real bug, found in a 2026-08-20 branch
    /// review: `reattachBackgroundSession` below is the *only* place a
    /// background session gets recreated, and it only ever runs from
    /// `AppDelegate.application(_: handleEventsForBackgroundURLSession:
    /// completionHandler:)` — which the OS calls exclusively when it
    /// specifically relaunches the app in the background to deliver a
    /// finished background session's queued events. A perfectly ordinary
    /// relaunch (force-quit + reopen from the home screen while a download
    /// was still transferring, or a jetsam kill under memory pressure
    /// followed by a plain tap) never goes through that path at all — so
    /// without this, a `.downloading` row surviving a plain relaunch had no
    /// session ever recreated for it, leaving it stuck at "Downloading…"
    /// forever with nothing actually transferring and no way to recover
    /// short of manual delete.
    ///
    /// Doesn't register the reattached session as occupying a concurrency
    /// slot (`delegates[itemID]`) until `finishReattaching` below confirms,
    /// via `getTasksWithCompletionHandler`, that the identifier actually
    /// still has a real download task behind it. A second real bug, found
    /// live the same day right after the first shipped: the original
    /// version registered *every* `.downloading` row unconditionally and
    /// synchronously, with no way to distinguish a genuinely in-flight
    /// transfer from a stale row left over from earlier testing (this
    /// SwiftData store persists across relaunches/reinstalls, and this
    /// feature has been iterated on live for days) — a stale row
    /// permanently occupied a slot forever, since nothing would ever call
    /// its delegate to free it, silently jamming the *entire* download
    /// queue behind it; worse, redownloading that same item hit a
    /// session-identifier-reuse race when `delete(itemID:)` invalidated
    /// the phantom session and a fresh one was created under the identical
    /// background identifier moments later — the same class of bug as the
    /// original "-999" issue, just triggered at a different point.
    ///
    /// This does mean a genuinely-live reattached row's slot isn't
    /// reserved by the time `resumePendingQueue()` (called right after, in
    /// `init`) runs its own synchronous admission pass — a `.queued` row
    /// could get admitted immediately without "seeing" this one's not-yet-
    /// confirmed claim on a slot, which can transiently push the real
    /// concurrent-transfer count one over the configured limit until
    /// something finishes. A self-correcting, cosmetic overage — far
    /// preferable to the alternative of a stale row jamming the queue
    /// forever, which is what the synchronous version above risked to
    /// avoid it.
    private func reattachInFlightDownloads() {
        for row in store.allItems() where row.status == .downloading {
            let itemID = row.itemID
            guard delegates[itemID] == nil, !reattachmentPending.contains(itemID) else { continue }
            if let reattachVideoDownloadOverride {
                // Test seam: no real `URLSession` to introspect, so this
                // stays synchronous and unconditional — `DownloadManagerTests`
                // drives the "is it actually live" question itself via
                // whichever behavior the override simulates.
                delegates[itemID] = makeVideoDownloadDelegate(itemID: itemID, relativePath: row.videoFilePath)
                reattachVideoDownloadOverride(itemID)
                continue
            }
            // Claimed *before* the async check below starts, not after it
            // resolves — a real bug, confirmed live (2026-08-20, force-quit
            // mid-download): the window between starting this check and it
            // resolving is exactly when `reattachBackgroundSession` (fired
            // by the OS's own `handleEventsForBackgroundURLSession`
            // callback — which a force-quit-mid-download relaunch triggers
            // almost immediately) could independently decide `delegates
            // [itemID] == nil` still holds and create its *own* second
            // `URLSession` for the identical background identifier. Two
            // live `URLSession` objects for one identifier in the same
            // process is exactly the kind of conflict the OS resolves by
            // cancelling the underlying task out from under one of them —
            // confirmed live as the source of an `NSURLErrorCancelled`
            // (-999) on a download that should have resumed cleanly.
            // `reattachBackgroundSession` below checks this same set before
            // proceeding, so only one of the two paths ever actually
            // creates a session for a given itemID.
            reattachmentPending.insert(itemID)
            let delegate = makeVideoDownloadDelegate(itemID: itemID, relativePath: row.videoFilePath)
            let configuration = Self.makeBackgroundConfiguration(identifier: Self.backgroundSessionIdentifierPrefix + itemID)
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            session.getTasksWithCompletionHandler { [weak self] _, _, downloadTasks in
                Task { @MainActor in
                    self?.finishReattaching(itemID: itemID, session: session, delegate: delegate, hasLiveTask: !downloadTasks.isEmpty)
                }
            }
        }
    }

    /// See `reattachInFlightDownloads`'s own doc comment for the bugs this
    /// fixes. `hasLiveTask == false` means the identifier had nothing real
    /// behind it — the row is marked `.failed` (not left at `.downloading`
    /// with no path forward, and not silently reset to `.queued` either,
    /// which would auto-retry a transcode the user may not still want)
    /// rather than permanently claiming a slot no download will ever
    /// actually use.
    private func finishReattaching(itemID: String, session: URLSession, delegate: DownloadSessionDelegate, hasLiveTask: Bool) {
        reattachmentPending.remove(itemID)
        guard hasLiveTask else {
            session.invalidateAndCancel()
            if let row = store.item(itemID: itemID), row.status == .downloading {
                row.status = .failed
                row.errorMessage = String(localized: "The download was interrupted and couldn't be resumed. Try downloading again.")
                store.save()
            }
            return
        }
        // Defensive, shouldn't actually trigger now that `reattachBackgroundSession`
        // also honors `reattachmentPending` — but if something still raced
        // in and claimed this itemID while the check above was in flight,
        // don't clobber whatever it already registered.
        guard delegates[itemID] == nil else {
            session.invalidateAndCancel()
            return
        }
        delegates[itemID] = delegate
        sessions[itemID] = session
    }

    // MARK: - Video download (background session)

    /// Shared by `startVideoDownload` and every reattachment path
    /// (`reattachBackgroundSession`, `reattachInFlightDownloads`) — a real
    /// bug, found in the same 2026-08-20 review: `reattachBackgroundSession`
    /// used to build a fresh, un-configured `URLSessionConfiguration
    /// .background(withIdentifier:)` and never applied
    /// `downloadRequestTimeout`/`downloadResourceTimeout`, silently
    /// reverting to `URLSessionConfiguration`'s system default
    /// (`timeoutIntervalForResource`'s default is measured in days) for any
    /// download resumed via reattachment — exactly the long-running 4K
    /// transcode case `downloadResourceTimeout`'s own doc comment exists to
    /// bound.
    private static func makeBackgroundConfiguration(identifier: String) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.timeoutIntervalForRequest = downloadRequestTimeout
        configuration.timeoutIntervalForResource = downloadResourceTimeout
        return configuration
    }

    private func startVideoDownload(itemID: String, url: URL, relativePath: String) {
        let delegate = makeVideoDownloadDelegate(itemID: itemID, relativePath: relativePath)
        delegates[itemID] = delegate
        let configuration = Self.makeBackgroundConfiguration(identifier: Self.backgroundSessionIdentifierPrefix + itemID)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        sessions[itemID] = session
        session.downloadTask(with: url).resume()
    }

    /// Recovers which item a background session identifier belongs to
    /// (`backgroundSessionIdentifierPrefix` is a deterministic, reversible
    /// prefix — see its own doc comment) and re-attaches a session with the
    /// same identifier, which is what actually resumes delivering delegate
    /// callbacks for tasks that finished while the app was suspended or
    /// terminated. Called from `AppDelegate.application(_:
    /// handleEventsForBackgroundURLSession:completionHandler:)` via
    /// `NotificationCenter` — see `init`. Covers the OS-triggered
    /// background-relaunch case specifically; `reattachInFlightDownloads`
    /// above covers the plain-relaunch case this alone doesn't — and, since
    /// a force-quit mid-download is exactly the scenario that triggers
    /// *both* this OS callback and `reattachInFlightDownloads`'s own launch
    /// sweep, this also has to back off (`reattachmentPending`) while that
    /// one's own async liveness check for the same itemID is still in
    /// flight, or both paths can end up creating independent `URLSession`s
    /// for the identical background identifier — see
    /// `reattachInFlightDownloads`'s own doc comment for the confirmed-live
    /// `-999` this caused.
    private func reattachBackgroundSession(identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier.hasPrefix(Self.backgroundSessionIdentifierPrefix) else { return }
        let itemID = String(identifier.dropFirst(Self.backgroundSessionIdentifierPrefix.count))
        backgroundCompletionHandlers[itemID] = completionHandler
        guard delegates[itemID] == nil, !reattachmentPending.contains(itemID) else { return }
        let delegate = makeVideoDownloadDelegate(itemID: itemID, relativePath: DownloadFileStore.videoRelativePath(itemID: itemID))
        delegates[itemID] = delegate
        sessions[itemID] = URLSession(configuration: Self.makeBackgroundConfiguration(identifier: identifier), delegate: delegate, delegateQueue: nil)
    }

    private func makeVideoDownloadDelegate(itemID: String, relativePath: String) -> DownloadSessionDelegate {
        // Computed once, not re-queried on every `didWriteData` tick
        // (which can fire many times a second) — the estimate is fixed
        // for the life of this download anyway (runtime/bitrate are set
        // once at enqueue time and never change). See `DownloadedItem
        // .estimatedTotalBytes`'s doc comment for how this number is
        // derived, and `DownloadProgress.totalBytesExpected`'s for why
        // it's needed at all (the transfer itself never reports a real
        // `Content-Length`).
        let estimatedTotalBytes = store.item(itemID: itemID)?.estimatedTotalBytes ?? 0
        return DownloadSessionDelegate(
            destinationRelativePath: relativePath,
            onProgress: { [weak self] downloaded, expected in
                let total = expected > 0 ? expected : estimatedTotalBytes
                self?.activeDownloads[itemID] = DownloadProgress(bytesDownloaded: downloaded, totalBytesExpected: total)
            },
            onCompletion: { [weak self] result in
                guard let self else { return }
                self.activeDownloads[itemID] = nil
                self.delegates[itemID] = nil
                // A real leak, found in a 2026-08-20 branch review: a
                // `URLSession` created with an explicit delegate (not
                // `.shared`) retains itself *and* its delegate until
                // explicitly invalidated — dropping this manager's own
                // reference alone doesn't deallocate it. Every completed/
                // failed download used to leak one `URLSession`, its
                // delegate queue, and this `DownloadSessionDelegate`
                // instance for the rest of the process's lifetime.
                // `finishTasksAndInvalidate()`, not `invalidateAndCancel()`
                // — the transfer already finished (success or failure), so
                // there's nothing in flight left to cancel.
                self.sessions[itemID]?.finishTasksAndInvalidate()
                self.sessions[itemID] = nil
                // A slot just freed up — try to admit whatever's next in
                // line regardless of whether this row still exists below
                // (it may have been deleted mid-download).
                self.admitQueuedDownloadsIfPossible()
                guard let row = self.store.item(itemID: itemID) else { return }
                switch result {
                case .success:
                    row.status = .completed
                    row.errorMessage = nil
                case .failure(let error):
                    row.status = .failed
                    row.errorMessage = Self.friendlyDownloadFailureMessage(for: error)
                }
                self.store.save()
            },
            onFinishedEvents: { [weak self] in
                self?.backgroundCompletionHandlers.removeValue(forKey: itemID)?()
            }
        )
    }

    // MARK: - Delete

    /// Always frees the on-disk video/subtitle files (never shared with
    /// another item) and, for each of the four possibly-shared image
    /// fields, frees the file only if no other row still references it
    /// (`DownloadFileStore.deleteImageIfUnreferenced`). The `DownloadedItem`
    /// row itself is removed immediately unless it still has an unsynced
    /// watched/resume write (`pendingSync`) — in that case the row survives
    /// with `markedForDeletion = true` purely to carry that write; see the
    /// offline-downloads plan's "Delete semantics" section and
    /// `DownloadSyncManager`, which removes the row for real once that sync
    /// succeeds.
    ///
    /// Also cancels the item's in-flight background session, if it still
    /// has one — a real bug, found live (2026-08-20, "Rushmore"): deleting
    /// a `.downloading` row used to only drop this manager's own delegate
    /// reference, never the underlying `URLSessionDownloadTask` itself,
    /// which — being a *background* transfer — keeps right on running at
    /// the OS level, orphaned, under `com.dionysus.downloads.<itemID>`
    /// (`backgroundSessionIdentifierPrefix` is deterministic and
    /// itemID-only, no per-attempt suffix). A same-day re-download of that
    /// same item then reused that identifier while the OS still considered
    /// it "in use" by the orphaned transfer, and the *new* background
    /// session's task was cancelled almost immediately —
    /// `NSURLErrorCancelled` (-999). Actually invalidating the old session
    /// here frees the identifier for real, so a later re-download starts
    /// clean.
    func delete(itemID: String) {
        guard let downloaded = store.item(itemID: itemID) else { return }
        DownloadFileStore.deleteItemFiles(itemID: itemID)
        // Fetched once and reused across all four checks below — each used
        // to independently call `store.allItems()` (a full SwiftData
        // deserialization of every row), so a single `delete(itemID:)`
        // call did 4 full-table fetches; a bulk delete (a whole show/
        // season, looping this once per episode) multiplied that further.
        let allItems = store.allItems()
        for path in [downloaded.posterImagePath, downloaded.backdropImagePath, downloaded.logoImagePath, downloaded.thumbImagePath] {
            DownloadFileStore.deleteImageIfUnreferenced(relativePath: path, excludingItemID: itemID, store: store, among: allItems)
        }
        // `delegates[itemID] != nil` is exactly "this item's background
        // session actually started" (see that property's own doc comment)
        // — gating the cancel on it keeps this a no-op for a row that was
        // still `.queued` and never got as far as a real session to cancel,
        // matching what `sessions.removeValue(forKey:)` alone would do in
        // the non-overridden path anyway.
        let wasActivelyDownloading = delegates[itemID] != nil
        activeDownloads[itemID] = nil
        delegates[itemID] = nil
        if wasActivelyDownloading {
            if let cancelVideoDownloadOverride {
                cancelVideoDownloadOverride(itemID)
            } else if let session = sessions.removeValue(forKey: itemID) {
                session.invalidateAndCancel()
            }
        }
        // Only meaningful for a row that was still waiting for a
        // concurrency slot (never got as far as starting a real
        // `URLSessionDownloadTask`) — a harmless no-op otherwise.
        pendingQueue.removeAll { $0 == itemID }

        if downloaded.pendingSync {
            downloaded.markedForDeletion = true
            store.save()
            // A real bug, found live (2026-08-20): without this, the only
            // trigger that ever clears a `markedForDeletion` row is the
            // next scenePhase foreground/reconnect transition
            // (`DownloadSyncManager`'s own doc comment) — delete while the
            // app is already active and stays active, and the row (plus
            // whatever `DownloadButton.isPendingDeletion` spinner still
            // points at it on a live page) could sit stuck indefinitely
            // with nothing left to prompt a sync. See `onRowMarkedForDeletion`'s
            // own doc comment for why this is a closure rather than a
            // stored `client` reference.
            onRowMarkedForDeletion?()
        } else {
            store.delete(downloaded)
        }
        // A `.downloading` row just had its concurrency slot freed above
        // (`delegates[itemID] = nil`) — admit whatever's next in line
        // immediately rather than leaving it `.queued` until some other,
        // unrelated event happens to call this.
        admitQueuedDownloadsIfPossible()
    }

    #if DEBUG
    // MARK: - Test seam (DownloadManagerTests only — see `startVideoDownloadOverride`)

    /// Frees a concurrency slot `admitQueuedDownloadsIfPossible` reserved
    /// (see its own doc comment on why that reservation happens
    /// unconditionally, before either the real or test-override starter
    /// runs) and admits the next queued item, exactly like the real
    /// `onCompletion` closure does. `#if DEBUG`-gated the same way
    /// `PreviewPlaybackEngine` is: compiled out of Release, available to
    /// the test target.
    func test_simulateDownloadFinished(itemID: String) {
        delegates[itemID] = nil
        admitQueuedDownloadsIfPossible()
    }
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
