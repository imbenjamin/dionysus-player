import Foundation
import SwiftData

/// Movie vs. episode — drives `DownloadsView`'s grouping (a standalone row
/// vs. a per-show group row) without needing a network round trip.
enum DownloadedItemKind: String, Codable {
    case movie
    case episode
}

/// Lifecycle of one offline download.
enum DownloadStatus: String, Codable {
    case queued
    case downloading
    case paused
    case completed
    case failed
}

/// A subtitle sidecar captured at download time — image-based (PGS/VobSub/
/// DVB) tracks are skipped entirely before this is ever created, see
/// `JellyfinAPIClient.isImageBasedSubtitleCodec`.
struct DownloadedSubtitleFile: Codable, Equatable {
    var index: Int
    var language: String?
    var displayTitle: String
    var isForced: Bool
    var isDefault: Bool
    var isHearingImpaired: Bool
    /// Relative to `DownloadFileStore`'s root.
    var relativePath: String
}

/// Mirrors `PlaybackSegment` for offline storage — a plain start/end-
/// seconds/kind snapshot. Not `PlaybackSegment` itself: that type is built
/// straight from a live `MediaSegmentDto` fetch and has no `Codable`
/// conformance of its own, nor any other reason to need one outside this.
struct DownloadedSegment: Codable, Equatable {
    enum Kind: String, Codable {
        case intro, outro, recap, preview, commercial
    }
    var kind: Kind
    var startSeconds: Double
    var endSeconds: Double
}

/// A cast/crew credit captured at download time — name/role only, no
/// headshot image (explicit scope cut to bound per-item storage; offline
/// cast rows fall back to a generic person glyph).
struct DownloadedPerson: Codable, Equatable {
    var name: String
    var role: String?
}

/// Metadata snapshot captured once at enqueue time from the same
/// `BaseItemDto` the download flow already has in hand — see the
/// offline-downloads plan's "Metadata, artwork, and skip-segments" section.
/// Deliberately excludes anything relational to other items (similar items,
/// collection membership), which only make sense against a live, browsable
/// library.
struct DownloadedItemMetadata: Codable, Equatable {
    var overview: String?
    var taglines: [String]
    var genres: [String]
    /// Raw studio/network names — `DownloadedAssetDetailView` applies the
    /// same "Network" relabeling for a show that `CollectionGridView`
    /// already does live; this just stores the names either way.
    var studios: [String]
    var productionYear: Int?
    var premiereDate: Date?
    var communityRating: Double?
    var officialRating: String?
    var people: [DownloadedPerson]
}

/// One offline-downloaded item — a movie or episode, its device-transcoded
/// video file, sidecar subtitles, a metadata/artwork snapshot for fully
/// offline rendering, and local resume/watched tracking pending sync back to
/// the server. See the offline-downloads plan for the full design,
/// especially its "Delete semantics" section: a row can outlive its own
/// files (`markedForDeletion`) purely to carry a not-yet-pushed sync
/// payload, so `itemID` deliberately isn't the SwiftData delete boundary —
/// `DownloadManager.delete(itemID:)`/`DownloadSyncManager` are.
///
/// Enum-typed fields are stored as their raw `String` via a private
/// `...Raw` property with a computed wrapper, not as the enum directly —
/// the conventional SwiftData-safe pattern for enum properties.
@Model
final class DownloadedItem: Identifiable {
    /// Satisfies `Identifiable` for `ForEach`/`List` use in the Downloads UI
    /// — SwiftData's `@Model` macro doesn't synthesize this on its own
    /// unless a stored property is literally named `id`, and `itemID` (the
    /// meaningful, unique identity — see its own `@Attribute(.unique)`) is
    /// named to match this app's `MediaItem`/`BaseItemDto` convention
    /// instead.
    var id: String { itemID }

    @Attribute(.unique) var itemID: String
    var userID: String
    var mediaSourceID: String?
    private var kindRaw: String
    var title: String

    // Show parentage — `nil` for a movie.
    var seriesID: String?
    var seriesTitle: String?
    var seasonID: String?
    var seasonNumber: Int?
    var episodeNumber: Int?
    var episodeLabel: String?
    var runtimeTicks: Int64?

    // Requested tier.
    private var requestedResolutionRaw: String
    private var requestedPresetRaw: String

    // Achieved technical specs (what was actually requested from the
    // transcoder — see `DownloadTranscodeCalculator.target`).
    var videoCodec: String?
    var audioCodec: String?
    var width: Int?
    var height: Int?
    var bitrate: Int?
    /// Whether the *transcoded output* is actually HDR — currently always
    /// `false` (see `DownloadManager.enqueue`'s doc comment at its own
    /// `isHDR:` argument): this app doesn't yet send a `DeviceProfile` on
    /// the download path, so Jellyfin's transcoder has no declared
    /// HDR-capable target to preserve HDR for and tone-maps to SDR by
    /// default, regardless of the source's own dynamic range or the
    /// `VideoProfile=main10` this still requests. Deliberately *not* just
    /// mirroring the source's HDR-ness — confirmed live that doing so
    /// produced a misleading "HDR" badge on a download that actually
    /// played back as SDR.
    var isHDR: Bool

    var selectedAudioTrackIndex: Int?
    var selectedAudioTrackTitle: String?

    /// Relative to `DownloadFileStore`'s root.
    var videoFilePath: String
    var subtitleFiles: [DownloadedSubtitleFile]
    /// Display titles of subtitle tracks skipped for being image-based —
    /// shown in the Downloads UI so the omission isn't silent.
    var skippedSubtitleTracks: [String]

    private var statusRaw: String
    var totalBytesExpected: Int64
    var bytesDownloaded: Int64
    var errorMessage: String?
    /// The resolved transcode stream URL for this item's video, captured
    /// once at enqueue time — needed to actually start the background
    /// `URLSessionDownloadTask` whenever a concurrency slot frees up (see
    /// `DownloadPreferencesStore.maxConcurrentDownloads`), which can happen
    /// much later than the original `enqueue()` call: a `.queued` row can
    /// easily outlive the app being foregrounded (e.g. a season's worth of
    /// episodes waiting behind a low limit), so this can't just live in an
    /// in-memory dictionary the way a same-session-only value could —
    /// `DownloadManager` rebuilds its pending queue from whichever rows
    /// still have one of these on a fresh launch. `nil` once the video task
    /// has actually started (cleared by `DownloadManager
    /// .admitQueuedDownloadsIfPossible`) — nothing needs it again after
    /// that point.
    var pendingDownloadURLString: String?

    var createdAt: Date
    var resumePositionTicks: Int64
    var isPlayed: Bool
    var playedPercentage: Double
    /// The real, on-device moment this item was actually last played
    /// offline (`PlayerViewModel.writeOfflineProgress` sets this to
    /// `Date()` at every progress tick and on stop, on the device, while
    /// it happened) — distinct from `lastSyncedAt` below (when the pending
    /// write finally reached the server, possibly hours/days later once
    /// reconnected). `DownloadSyncManager` sends this as `LastPlayedDate`
    /// so Jellyfin's own Continue Watching ordering reflects when the user
    /// actually watched it, not when the app happened to reconnect —
    /// without an explicit value here, the server stamps its own
    /// `LastPlayedDate` as the moment of the sync POST, which is exactly
    /// wrong for something watched well before that.
    var lastPlayedAt: Date?

    /// True when local resume/watched state has changed since the last
    /// successful `updateUserData` push — see `DownloadSyncManager`.
    var pendingSync: Bool
    var lastSyncedAt: Date?
    /// True once the user has deleted this download while `pendingSync`
    /// was still true — the row (and only the row; its files are always
    /// deleted immediately) survives purely to carry that not-yet-pushed
    /// sync payload. See the offline-downloads plan's "Delete semantics"
    /// section. UI list/detail screens must filter these out.
    var markedForDeletion: Bool

    var metadata: DownloadedItemMetadata
    /// Each image path may be shared with other `DownloadedItem` rows (a
    /// series logo/backdrop reused across episodes) — see
    /// `DownloadFileStore`'s and `DownloadManager.delete(itemID:)`'s doc
    /// comments for the content-addressing/reference-check this implies.
    var posterImagePath: String?
    var backdropImagePath: String?
    var logoImagePath: String?
    var thumbImagePath: String?
    var segments: [DownloadedSegment]

    var kind: DownloadedItemKind {
        get { DownloadedItemKind(rawValue: kindRaw) ?? .movie }
        set { kindRaw = newValue.rawValue }
    }
    var status: DownloadStatus {
        get { DownloadStatus(rawValue: statusRaw) ?? .failed }
        set { statusRaw = newValue.rawValue }
    }
    var requestedResolution: DownloadResolution {
        get { DownloadResolution(rawValue: requestedResolutionRaw) ?? .hd1080p }
        set { requestedResolutionRaw = newValue.rawValue }
    }
    var requestedPreset: DownloadBitratePreset {
        get { DownloadBitratePreset(rawValue: requestedPresetRaw) ?? .normal }
        set { requestedPresetRaw = newValue.rawValue }
    }

    /// Estimated total download size in bytes, from data already fixed at
    /// enqueue time — Jellyfin's live-transcode stream never reports a
    /// `Content-Length` (see `DownloadProgress.totalBytesExpected`'s doc
    /// comment), but the item's own known runtime and target video/audio
    /// bitrates let this be estimated closely: `(videoBitrate +
    /// audioBitrate) * durationSeconds / 8`. `DownloadManager` uses this as
    /// a determinate progress total in place of the (permanently unknown)
    /// server-reported one. An estimate, not a guarantee — real encoder
    /// output varies around a target bitrate, so the actual file can land
    /// a bit above or below this; `DownloadProgress.fractionCompleted`
    /// clamps to 100% regardless. `nil` when there's nothing to estimate
    /// from (missing runtime or bitrate — shouldn't happen in practice,
    /// both are always set together at enqueue time).
    var estimatedTotalBytes: Int64? {
        guard let runtimeTicks, runtimeTicks > 0, let bitrate else { return nil }
        let durationSeconds = Double(runtimeTicks) / 10_000_000
        let totalBitsPerSecond = Double(bitrate) + Double(requestedPreset.audioBitrate)
        return Int64((totalBitsPerSecond * durationSeconds) / 8)
    }

    init(
        itemID: String,
        userID: String,
        mediaSourceID: String?,
        kind: DownloadedItemKind,
        title: String,
        seriesID: String? = nil,
        seriesTitle: String? = nil,
        seasonID: String? = nil,
        seasonNumber: Int? = nil,
        episodeNumber: Int? = nil,
        episodeLabel: String? = nil,
        runtimeTicks: Int64? = nil,
        requestedResolution: DownloadResolution,
        requestedPreset: DownloadBitratePreset,
        videoCodec: String? = nil,
        audioCodec: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        bitrate: Int? = nil,
        isHDR: Bool = false,
        selectedAudioTrackIndex: Int? = nil,
        selectedAudioTrackTitle: String? = nil,
        videoFilePath: String,
        subtitleFiles: [DownloadedSubtitleFile] = [],
        skippedSubtitleTracks: [String] = [],
        status: DownloadStatus = .queued,
        totalBytesExpected: Int64 = 0,
        bytesDownloaded: Int64 = 0,
        errorMessage: String? = nil,
        pendingDownloadURLString: String? = nil,
        createdAt: Date = Date(),
        resumePositionTicks: Int64 = 0,
        isPlayed: Bool = false,
        playedPercentage: Double = 0,
        lastPlayedAt: Date? = nil,
        pendingSync: Bool = false,
        lastSyncedAt: Date? = nil,
        markedForDeletion: Bool = false,
        metadata: DownloadedItemMetadata,
        posterImagePath: String? = nil,
        backdropImagePath: String? = nil,
        logoImagePath: String? = nil,
        thumbImagePath: String? = nil,
        segments: [DownloadedSegment] = []
    ) {
        self.itemID = itemID
        self.userID = userID
        self.mediaSourceID = mediaSourceID
        self.kindRaw = kind.rawValue
        self.title = title
        self.seriesID = seriesID
        self.seriesTitle = seriesTitle
        self.seasonID = seasonID
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.episodeLabel = episodeLabel
        self.runtimeTicks = runtimeTicks
        self.requestedResolutionRaw = requestedResolution.rawValue
        self.requestedPresetRaw = requestedPreset.rawValue
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.width = width
        self.height = height
        self.bitrate = bitrate
        self.isHDR = isHDR
        self.selectedAudioTrackIndex = selectedAudioTrackIndex
        self.selectedAudioTrackTitle = selectedAudioTrackTitle
        self.videoFilePath = videoFilePath
        self.subtitleFiles = subtitleFiles
        self.skippedSubtitleTracks = skippedSubtitleTracks
        self.statusRaw = status.rawValue
        self.totalBytesExpected = totalBytesExpected
        self.bytesDownloaded = bytesDownloaded
        self.errorMessage = errorMessage
        self.pendingDownloadURLString = pendingDownloadURLString
        self.createdAt = createdAt
        self.resumePositionTicks = resumePositionTicks
        self.isPlayed = isPlayed
        self.playedPercentage = playedPercentage
        self.lastPlayedAt = lastPlayedAt
        self.pendingSync = pendingSync
        self.lastSyncedAt = lastSyncedAt
        self.markedForDeletion = markedForDeletion
        self.metadata = metadata
        self.posterImagePath = posterImagePath
        self.backdropImagePath = backdropImagePath
        self.logoImagePath = logoImagePath
        self.thumbImagePath = thumbImagePath
        self.segments = segments
    }
}
