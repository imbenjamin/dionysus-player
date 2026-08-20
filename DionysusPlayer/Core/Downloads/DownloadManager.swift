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

    var errorDescription: String? {
        switch self {
        case .missingMediaSource: return String(localized: "This item has no downloadable media source.")
        case .invalidDownloadURL: return String(localized: "Couldn't build a download URL for this item.")
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

    init(
        store: DownloadStore,
        preferences: DownloadPreferencesStore = DownloadPreferencesStore(),
        startVideoDownloadOverride: ((String, URL, String) -> Void)? = nil,
        cancelVideoDownloadOverride: ((String) -> Void)? = nil
    ) {
        self.store = store
        self.preferences = preferences
        self.startVideoDownloadOverride = startVideoDownloadOverride
        self.cancelVideoDownloadOverride = cancelVideoDownloadOverride
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

        let images = await client.makeImageURLBuilder()
        let posterPath = await downloadImageIfNeeded(sourceItemID: item.id, imageType: "Primary", tag: item.dto.imageTags?["Primary"], maxWidth: 500, images: images)

        // Backdrop/logo: own image if present, else the nearest ancestor's
        // (same fallback `MediaItem.backdropImageURL`/`logoImageURL` apply
        // live) — resolved to a concrete `(sourceItemID, tag)` pair up
        // front so there's just one `downloadImageIfNeeded` call site each,
        // rather than threading the fallback through an async-generic
        // helper.
        var backdropPath: String?
        if let tag = item.dto.backdropImageTags?.first {
            backdropPath = await downloadImageIfNeeded(sourceItemID: item.id, imageType: "Backdrop", tag: tag, maxWidth: 1600, images: images)
        } else if let parentID = item.dto.parentBackdropItemId, let tag = item.dto.parentBackdropImageTags?.first {
            backdropPath = await downloadImageIfNeeded(sourceItemID: parentID, imageType: "Backdrop", tag: tag, maxWidth: 1600, images: images)
        }

        var logoPath: String?
        if let tag = item.dto.imageTags?["Logo"] {
            logoPath = await downloadImageIfNeeded(sourceItemID: item.id, imageType: "Logo", tag: tag, maxWidth: 600, images: images)
        } else if let parentID = item.dto.parentLogoItemId, let tag = item.dto.parentLogoImageTag {
            logoPath = await downloadImageIfNeeded(sourceItemID: parentID, imageType: "Logo", tag: tag, maxWidth: 600, images: images)
        }

        let thumbPath = await downloadImageIfNeeded(sourceItemID: item.id, imageType: "Thumb", tag: item.dto.imageTags?["Thumb"], maxWidth: 500, images: images)

        let segments: [DownloadedSegment] = ((try? await client.mediaSegments(itemID: item.id)) ?? []).compactMap { dto in
            guard let kind = Self.downloadedSegmentKind(from: dto.type) else { return nil }
            return DownloadedSegment(kind: kind, startSeconds: Double(dto.startTicks) / 10_000_000, endSeconds: Double(dto.endTicks) / 10_000_000)
        }

        let trickplayInfo = await downloadTrickplayTiles(itemID: item.id, mediaSourceID: mediaSourceID, client: client, userID: userID, images: images)

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
            metadata: metadata,
            posterImagePath: posterPath,
            backdropImagePath: backdropPath,
            logoImagePath: logoPath,
            thumbImagePath: thumbPath,
            segments: segments,
            trickplayInfo: trickplayInfo
        )
        store.insert(downloaded)

        downloaded.subtitleFiles = await downloadSubtitles(
            itemID: item.id, mediaSourceID: mediaSourceID, tracks: subtitleTracks, client: client
        )
        store.save()

        queueVideoDownload(itemID: item.id)
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
        for sheetIndex in 0..<sheetCount {
            guard let url = images.trickplayTileURL(itemID: itemID, width: info.width, sheetIndex: sheetIndex) else { continue }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else { continue }
                let relativePath = DownloadFileStore.trickplayTileRelativePath(itemID: itemID, width: info.width, sheetIndex: sheetIndex)
                try DownloadFileStore.write(data, toRelativePath: relativePath)
            } catch {
                continue
            }
        }
        return info
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
        while canStartAnotherDownload {
            guard !pendingQueue.isEmpty else { return }
            let itemID = pendingQueue.removeFirst()
            guard let row = store.item(itemID: itemID), row.status == .queued,
                  let urlString = row.pendingDownloadURLString, let url = URL(string: urlString)
            else { continue }
            row.status = .downloading
            row.pendingDownloadURLString = nil
            store.save()
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
    /// survives via `reattachBackgroundSession`'s background `URLSession`
    /// reattachment): without this it would sit at `.queued` forever with
    /// nothing left to ever admit it. Ordered by `createdAt` so a relaunch
    /// preserves the same tap order the queue already promised within one
    /// session. Called once, from `init`.
    private func resumePendingQueue() {
        let queuedRows = store.allItems()
            .filter { $0.status == .queued && $0.pendingDownloadURLString != nil }
            .sorted { $0.createdAt < $1.createdAt }
        pendingQueue = queuedRows.map(\.itemID)
        admitQueuedDownloadsIfPossible()
    }

    // MARK: - Video download (background session)

    private func startVideoDownload(itemID: String, url: URL, relativePath: String) {
        let delegate = makeVideoDownloadDelegate(itemID: itemID, relativePath: relativePath)
        delegates[itemID] = delegate
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionIdentifierPrefix + itemID)
        configuration.timeoutIntervalForRequest = Self.downloadRequestTimeout
        configuration.timeoutIntervalForResource = Self.downloadResourceTimeout
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
    /// `NotificationCenter` — see `init`.
    private func reattachBackgroundSession(identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier.hasPrefix(Self.backgroundSessionIdentifierPrefix) else { return }
        let itemID = String(identifier.dropFirst(Self.backgroundSessionIdentifierPrefix.count))
        backgroundCompletionHandlers[itemID] = completionHandler
        let delegate = makeVideoDownloadDelegate(itemID: itemID, relativePath: DownloadFileStore.videoRelativePath(itemID: itemID))
        delegates[itemID] = delegate
        sessions[itemID] = URLSession(configuration: .background(withIdentifier: identifier), delegate: delegate, delegateQueue: nil)
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
                    row.errorMessage = error.localizedDescription
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
        for path in [downloaded.posterImagePath, downloaded.backdropImagePath, downloaded.logoImagePath, downloaded.thumbImagePath] {
            DownloadFileStore.deleteImageIfUnreferenced(relativePath: path, excludingItemID: itemID, store: store)
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
