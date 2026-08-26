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
    /// `isHDR:` argument): Jellyfin's transcoder tone-maps to SDR
    /// regardless of the source's own dynamic range. Deliberately *not*
    /// just mirroring the source's HDR-ness — that produced a misleading
    /// "HDR" badge on a download that actually played back as SDR.
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
    /// once at enqueue time — needed to start the background
    /// `URLSessionDownloadTask` whenever a concurrency slot frees up, which
    /// can happen much later (even after a relaunch), so this is persisted
    /// rather than kept in an in-memory dictionary; `DownloadManager`
    /// rebuilds its pending queue from whichever rows still have one on a
    /// fresh launch. `nil` once the video task has actually started.
    var pendingDownloadURLString: String?

    var createdAt: Date
    var resumePositionTicks: Int64
    var isPlayed: Bool
    var playedPercentage: Double
    /// The real, on-device moment this item was actually last played
    /// offline (`PlayerViewModel.writeOfflineProgress` sets this to
    /// `Date()` at every progress tick and on stop) — distinct from
    /// `lastSyncedAt` below (when the pending write finally reached the
    /// server, possibly much later). See `DownloadSyncManager`'s own doc
    /// comment for why this has to be sent explicitly as `LastPlayedDate`
    /// rather than left for the server to infer.
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
    /// `nil` when this download has no scrub-preview thumbnails — either
    /// the source item had no trickplay track scanned by the server yet
    /// (see `BaseItemDto.trickplay`'s own doc comment), or the fetch for it
    /// failed at enqueue time (best-effort — see `DownloadManager.enqueue`'s
    /// trickplay section, non-fatal to the download either way). The tile
    /// sheet JPEGs this describes live under `DownloadFileStore
    /// .trickplayTileRelativePath(itemID:width:sheetIndex:)`, not tracked
    /// individually here — `TrickplayMath.sheetCount(for:)` derives how many
    /// there are straight from this info, same as the live path derives it
    /// from a fetched `TrickplayInfo` with no separate file inventory.
    var trickplayInfo: TrickplayInfo?

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

    /// Estimated total download size in bytes — Jellyfin's live-transcode
    /// stream never reports a `Content-Length` (see `DownloadProgress
    /// .totalBytesExpected`), so this derives one from the item's known
    /// runtime and target bitrates instead: `(videoBitrate + audioBitrate)
    /// * durationSeconds / 8`. `nil` when there's nothing to estimate from
    /// (shouldn't happen in practice — runtime and bitrate are always set
    /// together at enqueue time).
    var estimatedTotalBytes: Int64? {
        guard let runtimeTicks, runtimeTicks > 0, let bitrate else { return nil }
        let durationSeconds = Double(runtimeTicks) / 10_000_000
        let totalBitsPerSecond = Double(bitrate) + Double(requestedPreset.audioBitrate)
        return Int64((totalBitsPerSecond * durationSeconds) / 8)
    }

    /// Same "Xh Ym" formatting as `MediaItem.durationText` — duplicated
    /// rather than shared since this type has no `BaseItemDto` of its own
    /// to share that logic with, just the one line of tick math. Shared
    /// across `DownloadedInfoMetadataRow` and `DownloadedEpisodeRow` so
    /// neither duplicates it a second time.
    var durationText: String? {
        guard let totalMinutes = durationTotalMinutes else { return nil }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    /// Same duration as `durationText`, worded out for VoiceOver — see
    /// `MediaItem.durationAccessibilityText`'s doc comment for why "1h 32m"
    /// needs this (VoiceOver mishears it as "One H Thirty Two Meters").
    var durationAccessibilityText: String? {
        guard let totalMinutes = durationTotalMinutes else { return nil }
        return Self.spokenDuration(totalMinutes: totalMinutes)
    }

    private var durationTotalMinutes: Int? {
        guard let runtimeTicks, runtimeTicks > 0 else { return nil }
        return Int(runtimeTicks / 10_000_000 / 60)
    }

    /// `resumePositionTicks`, worded out for VoiceOver — same
    /// `spokenDuration(totalMinutes:)` `durationAccessibilityText` uses,
    /// just from a different source value (elapsed time into the item, not
    /// its total runtime). `nil` whenever there's nothing to resume from.
    var resumePositionAccessibilityText: String? {
        guard resumePositionTicks > 0 else { return nil }
        return Self.spokenDuration(totalMinutes: Int(resumePositionTicks / 10_000_000 / 60))
    }

    /// `episodeLabel`, worded out for VoiceOver — see `MediaItem
    /// .episodeLabelAccessibilityText`'s doc comment for why "S1:E4" needs
    /// this. `nil` under the same conditions `episodeLabel` is.
    var episodeLabelAccessibilityText: String? {
        guard let seasonNumber, let episodeNumber else { return nil }
        return String(localized: "season \(seasonNumber) episode \(episodeNumber)")
    }

    /// Shared by `durationAccessibilityText`/`resumePositionAccessibilityText`
    /// — see `MediaItem`'s identical helper for why this needs
    /// `DateComponentsFormatter` rather than hand-rolled interpolation.
    private static func spokenDuration(totalMinutes: Int) -> String? {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = totalMinutes >= 60 ? [.hour, .minute] : [.minute]
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: TimeInterval(totalMinutes * 60))
    }

    /// An episode's exact release date, e.g. "1 Aug 2026" — the offline
    /// counterpart to `MediaItem.episodeAirDateText`; see that property's
    /// doc comment for why an individual episode shows its exact date
    /// rather than just a year. `nil` for a movie download, or an episode
    /// whose `metadata.premiereDate` wasn't captured at enqueue time.
    var episodeAirDateText: String? {
        guard kind == .episode, let date = metadata.premiereDate else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }

    /// Whichever of `episodeAirDateText`/the plain production year is the
    /// right level of detail for this download's kind — mirrors
    /// `MediaItem.metadataDateText`, see its doc comment for why the
    /// branching lives here rather than at each call site.
    var metadataDateText: String? {
        episodeAirDateText ?? metadata.productionYear.map(String.init)
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
        segments: [DownloadedSegment] = [],
        trickplayInfo: TrickplayInfo? = nil
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
        self.trickplayInfo = trickplayInfo
    }
}
