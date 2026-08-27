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

    var isTotalKnown: Bool { totalBytesExpected > 0 }

    /// `0` when `!isTotalKnown`. Clamped to `1` — `totalBytesExpected` is an
    /// estimate, and real encoder output can land slightly above it.
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
    /// Deterministic prefix + itemID for every background session
    /// identifier this manager hands out — lets a relaunch-triggered
    /// reattachment recover which item a bare identifier belongs to with
    /// no extra state to keep in sync.
    private static let backgroundSessionIdentifierPrefix = "com.dionysus.downloads."
    /// Jellyfin transcode jobs need to warm up before streaming bytes back.
    private static let downloadRequestTimeout: TimeInterval = 60
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
    /// transfer itself, not these. Rebuilt on each access (cheap — no
    /// connection opens until first use) so a mid-session preference
    /// change is always honored.
    private var adHocFetchSession: URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.allowsCellularAccess = !preferences.wifiOnly
        return URLSession(configuration: configuration)
    }

    /// Delegates keyed by itemID — kept alive here since `URLSession`
    /// doesn't retain its own delegate. Also doubles as the "how many
    /// video downloads are actually running" count
    /// (`canStartAnotherDownload`).
    private var delegates: [String: DownloadSessionDelegate] = [:]
    /// Stashed by a background relaunch (`reattachBackgroundSession`),
    /// called once that session reports every queued callback delivered.
    private var backgroundCompletionHandlers: [String: () -> Void] = [:]
    /// Item IDs waiting for a concurrency slot, FIFO, popped from the front
    /// by `admitQueuedDownloadsIfPossible`. Not the same as "every
    /// `.queued` row": an item can be `.queued` and not yet in here, for
    /// the brief window `enqueue` spends fetching subtitle sidecars first.
    private var pendingQueue: [String] = []
    /// Live background `URLSession`s, keyed by itemID — needed so
    /// `delete(itemID:)` can actually cancel an in-flight transfer, not
    /// just drop this manager's delegate reference to it.
    private var sessions: [String: URLSession] = [:]
    /// Item IDs `reattachInFlightDownloads`'s async liveness check has
    /// claimed but not yet resolved for — guards against it and
    /// `reattachBackgroundSession` both creating a session for the same
    /// itemID at once (see `reattachInFlightDownloads`'s doc comment).
    private var reattachmentPending: Set<String> = []
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
    /// touching `sessions` directly.
    private let cancelVideoDownloadOverride: ((String) -> Void)?
    /// Test-only DI seam: when set, `reattachInFlightDownloads` calls this
    /// instead of creating a real background `URLSession`.
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
        // Sweeps up files left behind by a row that's gone but whose
        // download task kept writing after — see
        // `DownloadFileStore.deleteOrphanedItemDirectories`.
        DownloadFileStore.deleteOrphanedItemDirectories(knownItemIDs: Set(store.allItems().map(\.itemID)))
        // Must run before `resumePendingQueue()` — it reserves in-flight
        // rows' concurrency slots first, so the queue's own admission pass
        // doesn't overshoot the configured limit.
        reattachInFlightDownloads()
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

        guard let downloadURL = await client.downloadStreamURL(
            itemID: item.id, mediaSourceID: mediaSourceID, audioStreamIndex: audioTrack?.index,
            resolution: resolution, preset: preset, isSourceHDR: isSourceHDR,
            sourceWidth: videoStream?.width, sourceHeight: videoStream?.height,
            sourceBitrate: sourceVideoBitrate, sourceVideoCodec: videoStream?.codec
        ) else { throw DownloadError.invalidDownloadURL }

        let target = DownloadTranscodeCalculator.target(
            resolution: resolution, preset: preset, isSourceHDR: isSourceHDR,
            sourceWidth: videoStream?.width, sourceHeight: videoStream?.height,
            sourceBitrate: sourceVideoBitrate, sourceVideoCodec: videoStream?.codec
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
                let (data, _) = try await session.data(from: url)
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
            let (data, response) = try await adHocFetchSession.data(from: url)
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
                        let (data, response) = try await session.data(from: url)
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
    /// the most common real-world failure: force-quitting the app cancels
    /// its background transfers by design (distinct from the OS suspending
    /// or killing a backgrounded app under memory pressure, which
    /// `reattachInFlightDownloads` recovers from) — `NSURLErrorCancelled`
    /// (-999) on reattachment reflects that real cancellation, not a bug,
    /// but still deserves a friendlier message than the raw error code.
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

    /// Rebuilds `pendingQueue` from `.queued` rows that survived to a fresh
    /// launch — unlike an already-started download (which reattaches via
    /// its background `URLSession`), a merely-queued row has no in-memory
    /// queue entry to resume from otherwise. Ordered by `createdAt` so a
    /// relaunch preserves tap order. Called from `init` **after**
    /// `reattachInFlightDownloads` — see that method's doc comment for why
    /// the order matters.
    private func resumePendingQueue() {
        let queuedRows = store.allItems()
            .filter { $0.status == .queued && $0.pendingDownloadURLString != nil }
            .sorted { $0.createdAt < $1.createdAt }
        pendingQueue = queuedRows.map(\.itemID)
        admitQueuedDownloadsIfPossible()
    }

    /// Recreates a background `URLSession` for every row still
    /// `.downloading` at launch. `reattachBackgroundSession` below only
    /// runs when the OS relaunches the app specifically to deliver a
    /// finished background session's events — an ordinary relaunch
    /// (force-quit + reopen, or a jetsam kill followed by a plain tap)
    /// never goes through it, so without this a `.downloading` row
    /// surviving either would sit stuck at "Downloading…" forever.
    ///
    /// Doesn't register the reattached session as occupying a concurrency
    /// slot until `finishReattaching` confirms, via
    /// `getTasksWithCompletionHandler`, that the identifier actually still
    /// has a real task behind it — a stale `.downloading` row (left over
    /// from earlier testing; this store persists across relaunches) would
    /// otherwise permanently occupy a slot and jam the whole queue behind
    /// it. `reattachmentPending` guards the async gap this creates: it and
    /// `reattachBackgroundSession` can both be triggered by the same
    /// force-quit-mid-download relaunch, and two live `URLSession`s for one
    /// background identifier get resolved by the OS cancelling one of them
    /// (`NSURLErrorCancelled`/-999) — only one of these two paths may
    /// actually create the session for a given itemID.
    ///
    /// Trade-off: a reattached row's slot isn't reserved until
    /// `finishReattaching` confirms it, so `resumePendingQueue()` (called
    /// right after, in `init`) can transiently admit one `.queued` row past
    /// the configured limit. Self-correcting and cosmetic — preferable to
    /// the stale-row-jams-the-queue alternative above.
    private func reattachInFlightDownloads() {
        for row in store.allItems() where row.status == .downloading {
            let itemID = row.itemID
            guard delegates[itemID] == nil, !reattachmentPending.contains(itemID) else { continue }
            if let reattachVideoDownloadOverride {
                // Test seam: no real `URLSession` to introspect, so this
                // stays synchronous — the override simulates liveness.
                delegates[itemID] = makeVideoDownloadDelegate(itemID: itemID, relativePath: row.videoFilePath)
                reattachVideoDownloadOverride(itemID)
                continue
            }
            // Claimed before the async check below starts, not after — see
            // this method's own doc comment for the race this avoids.
            reattachmentPending.insert(itemID)
            let delegate = makeVideoDownloadDelegate(itemID: itemID, relativePath: row.videoFilePath)
            let configuration = Self.makeBackgroundConfiguration(
                identifier: Self.backgroundSessionIdentifierPrefix + itemID, allowsCellularAccess: !preferences.wifiOnly
            )
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            session.getTasksWithCompletionHandler { [weak self] _, _, downloadTasks in
                Task { @MainActor in
                    self?.finishReattaching(itemID: itemID, session: session, delegate: delegate, hasLiveTask: !downloadTasks.isEmpty)
                }
            }
        }
    }

    /// See `reattachInFlightDownloads`'s doc comment for the bug this
    /// fixes. `hasLiveTask == false` means the identifier had nothing real
    /// behind it — marked `.failed` rather than reset to `.queued`, which
    /// would auto-retry a transcode the user may not still want.
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

    /// Shared by `startVideoDownload` and both reattachment paths — applies
    /// `downloadRequestTimeout`/`downloadResourceTimeout` explicitly, since
    /// a bare `.background(withIdentifier:)` configuration silently falls
    /// back to the system default (measured in days) otherwise.
    /// `allowsCellularAccess` is threaded through explicitly (rather than
    /// this method reading `preferences` itself) so it's evaluated fresh
    /// at each call site — `DownloadPreferencesStore.wifiOnly` gated
    /// nothing here before, silently letting a Wi-Fi-Only download run
    /// over cellular regardless of the setting. `waitsForConnectivity`
    /// pairs with it so a Wi-Fi-only transfer started without Wi-Fi
    /// available defers rather than failing outright.
    /// Not `private` — `DownloadManagerTests` asserts on the returned
    /// configuration directly (a pure function over its arguments, no real
    /// network involved) to cover the `allowsCellularAccess`/
    /// `waitsForConnectivity` wiring below without needing a real
    /// background `URLSession`.
    static func makeBackgroundConfiguration(identifier: String, allowsCellularAccess: Bool) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.timeoutIntervalForRequest = downloadRequestTimeout
        configuration.timeoutIntervalForResource = downloadResourceTimeout
        configuration.allowsCellularAccess = allowsCellularAccess
        configuration.waitsForConnectivity = true
        return configuration
    }

    private func startVideoDownload(itemID: String, url: URL, relativePath: String) {
        let delegate = makeVideoDownloadDelegate(itemID: itemID, relativePath: relativePath)
        delegates[itemID] = delegate
        let configuration = Self.makeBackgroundConfiguration(
            identifier: Self.backgroundSessionIdentifierPrefix + itemID, allowsCellularAccess: !preferences.wifiOnly
        )
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        sessions[itemID] = session
        session.downloadTask(with: url).resume()
    }

    /// Recovers which item a background session identifier belongs to
    /// (`backgroundSessionIdentifierPrefix` is deterministic/reversible)
    /// and re-attaches a session under the same identifier — what actually
    /// resumes delivering delegate callbacks for tasks that finished while
    /// suspended/terminated. Called from `AppDelegate.application(_:
    /// handleEventsForBackgroundURLSession:completionHandler:)` via
    /// `NotificationCenter` (see `init`). Covers the OS-triggered
    /// background-relaunch case; `reattachInFlightDownloads` covers the
    /// plain-relaunch case and explains the race between the two.
    private func reattachBackgroundSession(identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier.hasPrefix(Self.backgroundSessionIdentifierPrefix) else { return }
        let itemID = String(identifier.dropFirst(Self.backgroundSessionIdentifierPrefix.count))
        backgroundCompletionHandlers[itemID] = completionHandler
        guard delegates[itemID] == nil, !reattachmentPending.contains(itemID) else { return }
        let delegate = makeVideoDownloadDelegate(itemID: itemID, relativePath: DownloadFileStore.videoRelativePath(itemID: itemID))
        delegates[itemID] = delegate
        let configuration = Self.makeBackgroundConfiguration(identifier: identifier, allowsCellularAccess: !preferences.wifiOnly)
        sessions[itemID] = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    private func makeVideoDownloadDelegate(itemID: String, relativePath: String) -> DownloadSessionDelegate {
        // Computed once, not re-queried on every `didWriteData` tick — the
        // estimate is fixed for the life of this download (runtime/bitrate
        // don't change after enqueue).
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
                // A `URLSession` created with an explicit delegate retains
                // itself and its delegate until explicitly invalidated —
                // dropping this manager's own reference alone doesn't
                // deallocate it. `finishTasksAndInvalidate()`, not
                // `invalidateAndCancel()` — the transfer already finished,
                // so there's nothing in flight left to cancel.
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
        // Fetched once and reused across all four checks below, rather than
        // each independently re-fetching the full table.
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
            // Nudges DownloadSyncManager immediately rather than waiting
            // for the next scenePhase trigger — see `onRowMarkedForDeletion`'s
            // own doc comment.
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

    /// Frees a concurrency slot and admits the next queued item, mirroring
    /// what the real `onCompletion` closure does. Compiled out of Release.
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
