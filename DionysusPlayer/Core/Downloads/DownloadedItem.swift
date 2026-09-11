import Foundation
import SwiftData

/// Movie versus episode, driving `DownloadsView`'s grouping into standalone
/// rows or per-show groups with no network round trip.
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

/// A subtitle sidecar captured at download time. Image-based tracks are skipped
/// before this is created (see `JellyfinAPIClient.isImageBasedSubtitleCodec`).
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

/// `PlaybackSegment` for offline storage: a start/end/kind snapshot. Not that
/// type itself, which is built from a live `MediaSegmentDto` fetch and has no
/// reason to be `Codable`.
struct DownloadedSegment: Codable, Equatable {
    enum Kind: String, Codable {
        case intro, outro, recap, preview, commercial
    }
    var kind: Kind
    var startSeconds: Double
    var endSeconds: Double
}

/// `Chapter` for offline storage, as `DownloadedSegment` is for
/// `PlaybackSegment`: an index, name and start time, plus the relative path of
/// the still frame if one was fetched. Not `Chapter` itself, which resolves a
/// network URL and isn't `Codable`.
///
/// `index` is stored rather than re-derived from array position, so a rebuilt
/// `Chapter` keeps its "Chapter N" fallback number even if a best-effort fetch
/// stored a partial list.
struct DownloadedChapter: Codable, Equatable {
    var index: Int
    var name: String
    var startSeconds: Double
    /// Relative to `DownloadFileStore`'s root; `nil` when the chapter has no
    /// image server-side or its fetch failed.
    var imageRelativePath: String?
}

/// A cast or crew credit captured at download time: name and role only. Omitting
/// headshots bounds per-item storage, and offline cast rows fall back to a
/// generic person glyph.
struct DownloadedPerson: Codable, Equatable {
    var name: String
    var role: String?
}

/// Metadata captured once at enqueue from the `BaseItemDto` the download flow
/// already holds. Excludes anything relational — similar items, collection
/// membership — which only means something against a live library.
struct DownloadedItemMetadata: Codable, Equatable {
    var overview: String?
    var taglines: [String]
    var genres: [String]
    /// Raw studio names. `DownloadedAssetDetailView` applies the same "Network"
    /// relabeling for a show that `CollectionGridView` does live.
    var studios: [String]
    var productionYear: Int?
    var premiereDate: Date?
    var communityRating: Double?
    var officialRating: String?
    var people: [DownloadedPerson]
}

/// One offline-downloaded movie or episode: its transcoded video file, sidecar
/// subtitles, a metadata and artwork snapshot for fully offline rendering, and
/// local resume and watched state pending sync back to the server.
///
/// A row can outlive its own files, as `markedForDeletion`, purely to carry a
/// not-yet-pushed sync payload, so `itemID` is not the delete boundary —
/// `DownloadManager.delete(itemID:)` and `DownloadSyncManager` are.
///
/// Enum fields are stored as raw `String`s behind computed wrappers, the
/// SwiftData-safe pattern for enum properties.
@Model
final class DownloadedItem: Identifiable {
    /// Satisfies `Identifiable` for the Downloads UI. `@Model` synthesizes this
    /// only for a stored property literally named `id`, and the meaningful
    /// identity is `itemID`, named to match this app's DTO convention.
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

    // What was actually requested from the transcoder (see
    // `DownloadTranscodeCalculator.target`).
    var videoCodec: String?
    var audioCodec: String?
    var width: Int?
    var height: Int?
    var bitrate: Int?
    /// Whether the transcoded output is HDR, currently always `false`: Jellyfin
    /// tone-maps to SDR whatever the source's dynamic range. Not the source's
    /// own HDR-ness, which produced an "HDR" badge on a download that played
    /// back as SDR.
    var isHDR: Bool

    var selectedAudioTrackIndex: Int?
    var selectedAudioTrackTitle: String?

    /// Relative to `DownloadFileStore`'s root.
    var videoFilePath: String
    var subtitleFiles: [DownloadedSubtitleFile]
    /// Display titles of subtitle tracks skipped for being image-based, shown in
    /// the Downloads UI so the omission isn't silent.
    var skippedSubtitleTracks: [String]

    private var statusRaw: String
    var totalBytesExpected: Int64
    var bytesDownloaded: Int64
    var errorMessage: String?
    /// The transcode stream URL, captured at enqueue. Persisted rather than held
    /// in memory because the concurrency slot it waits for can free much later,
    /// even after a relaunch, and `DownloadManager` rebuilds its pending queue
    /// from the rows that still have one. `nil` once the task has started.
    var pendingDownloadURLString: String?

    var createdAt: Date
    var resumePositionTicks: Int64
    var isPlayed: Bool
    var playedPercentage: Double
    /// The on-device moment this was last played offline, set at every progress
    /// tick and on stop. Distinct from `lastSyncedAt`, which records when the
    /// pending write reached the server, possibly much later.
    var lastPlayedAt: Date?

    /// Local resume or watched state has changed since the last successful
    /// `updateUserData` push. See `DownloadSyncManager`.
    var pendingSync: Bool
    var lastSyncedAt: Date?
    /// The download was deleted while `pendingSync` was still true. Only the row
    /// survives — its files are deleted immediately — purely to carry that
    /// payload. UI screens must filter these out.
    var markedForDeletion: Bool

    var metadata: DownloadedItemMetadata
    /// Each path may be shared with other rows — a series logo or backdrop
    /// reused across episodes — so deletion needs the reference check in
    /// `DownloadManager.delete(itemID:)`.
    var posterImagePath: String?
    var backdropImagePath: String?
    var logoImagePath: String?
    var thumbImagePath: String?
    var segments: [DownloadedSegment]
    /// Chapter markers captured at enqueue, so the offline Chapters rail and the
    /// player's chapter picker work the same offline. Defaulted so SwiftData can
    /// migrate an existing row lightweightly instead of needing a schema bump.
    /// `[]` for an item with no real chapters, per `MediaItem.chapters`'
    /// single-entry rule.
    var chapters: [DownloadedChapter] = []
    /// `nil` when the download has no scrub-preview thumbnails: the server had
    /// scanned no trickplay track, or the best-effort fetch failed. The tile
    /// sheets live under
    /// `DownloadFileStore.trickplayTileRelativePath(itemID:width:sheetIndex:)`
    /// and aren't inventoried here — `TrickplayMath.sheetCount(for:)` derives
    /// their number from this info, as the live path does.
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

    /// Estimated total size. Jellyfin's live-transcode stream reports no
    /// `Content-Length`, so this derives one from runtime and target bitrates:
    /// `(videoBitrate + audioBitrate) * durationSeconds / 8`. `nil` with nothing
    /// to estimate from, which enqueue should never leave.
    var estimatedTotalBytes: Int64? {
        guard let runtimeTicks, runtimeTicks > 0, let bitrate else { return nil }
        let durationSeconds = Double(runtimeTicks) / 10_000_000
        let totalBitsPerSecond = Double(bitrate) + Double(requestedPreset.audioBitrate)
        return Int64((totalBitsPerSecond * durationSeconds) / 8)
    }

    /// Whether this item's artwork wants a 16:9 frame rather than a 2:3 poster:
    /// an episode's `Primary` image is a still frame. Mirrors
    /// `SearchResult.isLandscapeShaped`'s rule over the kinds this type has;
    /// `DownloadsRow.show` supplies the series half, having no single
    /// `DownloadedItem` to ask.
    ///
    /// Callers tally this across a whole grid rather than applying it per tile
    /// (see `DownloadsView.isLandscapeShape(_:)`).
    var isLandscapeShaped: Bool { kind == .episode }

    /// The downloaded artwork fitting the shape the grid chose, not this item's
    /// own kind — `SearchResult.imageURL(images:preferLandscape:)`'s preference
    /// applied to local paths. A movie in an episode-heavy landscape grid uses
    /// its `Thumb` if downloaded, else its poster cropped to fill rather than no
    /// artwork; the reverse for an episode in a portrait grid.
    func artworkRelativePath(preferLandscape: Bool) -> String? {
        preferLandscape
            ? (thumbImagePath ?? posterImagePath)
            : (posterImagePath ?? thumbImagePath)
    }

    /// `MediaItem.durationText`'s "Xh Ym" formatting, duplicated because this
    /// type has no `BaseItemDto` to share the tick math with.
    var durationText: String? {
        guard let totalMinutes = durationTotalMinutes else { return nil }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    /// `durationText` worded out for VoiceOver, which reads "1h 32m" as
    /// "One H Thirty Two Meters".
    var durationAccessibilityText: String? {
        guard let totalMinutes = durationTotalMinutes else { return nil }
        return Self.spokenDuration(totalMinutes: totalMinutes)
    }

    private var durationTotalMinutes: Int? {
        guard let runtimeTicks, runtimeTicks > 0 else { return nil }
        return Int(runtimeTicks / 10_000_000 / 60)
    }

    /// `resumePositionTicks` worded out for VoiceOver; `nil` with nothing to
    /// resume from.
    var resumePositionAccessibilityText: String? {
        guard resumePositionTicks > 0 else { return nil }
        return Self.spokenDuration(totalMinutes: Int(resumePositionTicks / 10_000_000 / 60))
    }

    /// `episodeLabel` worded out for VoiceOver, which can't read "S1:E4".
    var episodeLabelAccessibilityText: String? {
        guard let seasonNumber, let episodeNumber else { return nil }
        return String(localized: "season \(seasonNumber) episode \(episodeNumber)")
    }

    /// Shared by `durationAccessibilityText` and
    /// `resumePositionAccessibilityText`.
    private static func spokenDuration(totalMinutes: Int) -> String? {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = totalMinutes >= 60 ? [.hour, .minute] : [.minute]
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: TimeInterval(totalMinutes * 60))
    }

    /// `MediaItem.episodeAirDateText`'s offline counterpart. `nil` for a movie,
    /// and for an episode whose `metadata.premiereDate` wasn't captured.
    var episodeAirDateText: String? {
        guard kind == .episode, let date = metadata.premiereDate else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }

    /// `episodeAirDateText` or the production year, whichever suits this
    /// download's kind. Mirrors `MediaItem.metadataDateText`.
    var metadataDateText: String? {
        episodeAirDateText ?? metadata.productionYear.map(String.init)
    }

    /// "2019 · 1h 32m", a movie download's second line in `DownloadsView`,
    /// mirroring `MediaItem.railSubtitle`'s movie case so the offline list reads
    /// like the live one. `nil` only when both halves are missing. Episode
    /// downloads use `episodeLabel` and the title instead.
    var yearAndDurationText: String? {
        let parts = [metadata.productionYear.map(String.init), durationText].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    /// `yearAndDurationText`'s VoiceOver counterpart: a comma for the middle
    /// dot, and `durationAccessibilityText` for `durationText`.
    var yearAndDurationAccessibilityText: String? {
        let parts = [metadata.productionYear.map(String.init), durationAccessibilityText].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
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
        chapters: [DownloadedChapter] = [],
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
        self.chapters = chapters
        self.trickplayInfo = trickplayInfo
    }
}
