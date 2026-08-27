import Foundation

// MARK: - System

struct PublicSystemInfo: Codable {
    var localAddress: String?
    var serverName: String?
    var version: String?
    var productName: String?
    var id: String?
}

// MARK: - Auth

struct AuthenticateByNameRequest: Encodable {
    var username: String
    var pw: String
}

struct AuthenticationResult: Codable {
    var user: UserDto
    var accessToken: String
    var serverId: String?
}

struct UserDto: Codable, Identifiable {
    var id: String
    var name: String
    var hasPassword: Bool?
    var primaryImageTag: String?
}

// MARK: - Items

/// What kind of thing a `BaseItemDto` represents. Jellyfin's `Type` field is
/// an open-ended string in practice (plugins can add their own), so unknown
/// values decode to `.unknown` rather than failing.
enum BaseItemKind: String, Codable {
    case movie = "Movie"
    case series = "Series"
    case season = "Season"
    case episode = "Episode"
    case boxSet = "BoxSet"
    case collectionFolder = "CollectionFolder"
    case folder = "Folder"
    case playlist = "Playlist"
    // AUDIO SUPPRESSION: these five cases exist so audio/music types decode
    // to something explicit instead of falling into `.unknown` (which used
    // to route them straight into `MovieDetailView`'s default branch — see
    // `BaseItemDto.isAudioContent` below). Worth *keeping* once Dionysus
    // Player supports audio/music playback — at that point they'd route to
    // a real audio detail/playback path instead of an "unsupported" state,
    // not get deleted. `MusicVideo` is deliberately not a case here: it's a
    // real video file (just music-tagged) that already plays fine via the
    // `.unknown` → `MovieDetailView` fallback.
    case audio = "Audio"
    case audioBook = "AudioBook"
    case musicAlbum = "MusicAlbum"
    case musicArtist = "MusicArtist"
    case musicGenre = "MusicGenre"
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = BaseItemKind(rawValue: raw) ?? .unknown
    }
}

struct BaseItemDto: Codable, Identifiable {
    var id: String
    var name: String
    var overview: String?
    /// Marketing taglines. Jellyfin models this as an array but populates
    /// at most one entry in practice; only requested via `Fields=Taglines`
    /// on the detail page's own item fetch — see `MediaItem.tagline`.
    var taglines: [String]?
    var type: BaseItemKind

    var productionYear: Int?
    var endDate: Date?
    var premiereDate: Date?

    var communityRating: Double?
    var officialRating: String?
    var genres: [String]?
    /// Unlike `genres` (plain strings), Jellyfin represents studios as
    /// name+id pairs — used by `CollectionGridView`'s Studios filter.
    var studios: [NameGuidPair]?
    var runTimeTicks: Int64?

    // Episode/season parentage
    var seriesId: String?
    var seriesName: String?
    var seasonId: String?
    var seasonName: String?
    var indexNumber: Int?
    var parentIndexNumber: Int?
    var childCount: Int?

    // Images
    var imageTags: [String: String]?
    var backdropImageTags: [String]?
    /// Server-generated scrub-preview tile sheets — outer key is the
    /// `MediaSourceInfo.id` these thumbnails cover (a single item can have
    /// multiple versions/sources), inner key is a tile width in pixels as a
    /// string (e.g. `"320"`; a server can offer more than one resolution).
    /// Only populated when requested via `Fields=Trickplay`; `nil`/empty
    /// for content Jellyfin hasn't scanned for trickplay yet. See
    /// `TrickplayMath` for turning a scrub position into which tile of
    /// which sheet to show.
    var trickplay: [String: [String: TrickplayInfo]]?
    var parentBackdropItemId: String?
    var parentBackdropImageTags: [String]?
    /// Server-resolved: the nearest ancestor that actually has a logo (e.g.
    /// an episode's own Season, or failing that its Series), same mechanism
    /// as `parentBackdropItemId`/`parentBackdropImageTags` above.
    var parentLogoItemId: String?
    var parentLogoImageTag: String?

    var userData: UserItemDataDto?

    /// Only populated when requested via `Fields=MediaSources`; used for the
    /// detail page's technical-info section and to build a playback URL.
    var mediaSources: [MediaSourceInfo]?

    /// Only populated when requested via `Fields=People`; cast and crew for
    /// the detail page's "Cast & Crew" tab.
    var people: [BaseItemPerson]?

    /// Present on library "views" (e.g. `"movies"`, `"tvshows"`, `"boxsets"`)
    /// returned by `/Users/{id}/Views`; used to scope Home's rails.
    var collectionType: String?
    /// Jellyfin's own coarse content classification — `"Video"`, `"Audio"`,
    /// `"Photo"`, `"Book"`, or `"Unknown"` (its default, notably including
    /// the `MusicAlbum`/`MusicArtist` folder-like types, which don't carry
    /// a meaningful `MediaType` of their own — see
    /// `BaseItemDto.isAudioContent`, which keys off `type` for those two
    /// rather than this field). Reliable for leaf `Audio` items and for
    /// `Playlist` items (a playlist's own `MediaType` reflects its content).
    var mediaType: String?
}

/// `CollectionType` values `/Users/{id}/Views` can report for a library —
/// shared constants so `"movies"`/`"tvshows"`/`"boxsets"`/`"music"` aren't
/// repeated as raw string literals at each call site (`MediaItem
/// .libraryContentItemTypes`, `HomeViewModel.load()`).
enum JellyfinCollectionType {
    static let movies = "movies"
    static let tvShows = "tvshows"
    static let boxSets = "boxsets"
    // AUDIO SUPPRESSION: only referenced by `MediaItem.isAudioLibrary` to
    // hide a Music library from Home. Delete once Dionysus Player supports
    // browsing a Music library instead of hiding it.
    static let music = "music"
}

/// AUDIO SUPPRESSION: the one reusable source of truth for "is this item
/// audio/music content Dionysus Player can't play yet" — every suppression
/// check in the app (Home rails, detail screen, playback, downloads) calls
/// this rather than re-deriving the type/mediaType logic. Worth *keeping*
/// once audio support lands, repurposed to route to an audio player instead
/// of gating it out — see the doc comment on the new `BaseItemKind` cases
/// above.
extension BaseItemDto {
    var isAudioContent: Bool {
        switch type {
        case .audio, .audioBook, .musicAlbum, .musicArtist, .musicGenre:
            return true
        case .playlist:
            // Best-effort: an audio playlist reports `MediaType: "Audio"`,
            // but so does an *empty* playlist (server default with no
            // content to infer a type from) — over-suppressing an
            // edge-case empty non-audio playlist is the safe failure
            // direction here, unlike under-suppressing into a broken Play
            // button.
            return mediaType == "Audio"
        default:
            return false
        }
    }
}

/// A single cast/crew credit. Jellyfin's `Type` is as open-ended as
/// `BaseItemKind` (e.g. "Actor", "Director", "Writer", "GuestStar",
/// "Composer", ...) — kept as a plain string here since it's only ever
/// shown as a label, never branched on.
struct BaseItemPerson: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    /// The character name for an "Actor"/"GuestStar" credit; usually absent
    /// for crew, where `type` (e.g. "Director") is the meaningful label.
    var role: String?
    var type: String?
    var primaryImageTag: String?
}

/// Jellyfin's generic named-entity-with-id shape — used for
/// `BaseItemDto.studios`.
struct NameGuidPair: Codable, Hashable {
    var name: String
    var id: String?
}

extension BaseItemDto: Equatable, Hashable {
    static func == (lhs: BaseItemDto, rhs: BaseItemDto) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// One resolution of a Jellyfin server-generated trickplay track — a still
/// every `interval` ms across the item's full runtime, packed into
/// `tileWidth × tileHeight`-still tile-sheet JPEGs (row-major from the
/// top-left). See `TrickplayMath` for the seconds → sheet/tile lookup, and
/// `BaseItemDto.trickplay` for how these are keyed.
struct TrickplayInfo: Codable, Equatable {
    var width: Int
    var height: Int
    var tileWidth: Int
    var tileHeight: Int
    var thumbnailCount: Int
    var interval: Int
    var bandwidth: Int
}

struct UserItemDataDto: Codable {
    var playbackPositionTicks: Int64?
    var playedPercentage: Double?
    var played: Bool?
    var isFavorite: Bool?
}

struct BaseItemDtoQueryResult: Codable {
    var items: [BaseItemDto]
    var totalRecordCount: Int
}

// MARK: - Media Segments

/// Jellyfin's "Media Segments" feature (skippable Intro/Outro/Recap/Preview/
/// Commercial time ranges). Requires a Jellyfin server new enough to support
/// it — older servers just error on the endpoint, which
/// `PlayerViewModel.loadMediaSegments(for:)` tolerates the same way it
/// tolerates any other optional lookup failing.
enum MediaSegmentType: String, Codable {
    case intro = "Intro"
    case outro = "Outro"
    case recap = "Recap"
    case preview = "Preview"
    case commercial = "Commercial"
    case unknown = "Unknown"

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = MediaSegmentType(rawValue: raw) ?? .unknown
    }
}

struct MediaSegmentDto: Codable, Identifiable {
    var id: String
    var itemId: String
    var type: MediaSegmentType
    var startTicks: Int64
    var endTicks: Int64
}

struct MediaSegmentDtoQueryResult: Codable {
    var items: [MediaSegmentDto]
    var totalRecordCount: Int
}

// MARK: - Playback

struct PlaybackInfoRequest: Encodable {
    var userId: String
    /// Scopes the response to one specific version out of the item's
    /// `mediaSources` — the version-picker's choice on the detail page
    /// (`PlayResumeButtonRow`), or `nil` to let the server pick its own
    /// default (the pre-existing behavior, still used for the common
    /// single-version case).
    var mediaSourceId: String?
}

struct PlaybackInfoResponse: Codable {
    var mediaSources: [MediaSourceInfo]?
    var playSessionId: String?
}

struct MediaSourceInfo: Codable, Identifiable {
    var id: String?
    /// Server-computed, filename-derived (e.g. "[imdbid-tt8579674] -
    /// [Bluray-2160p][HDR10][x265]-GROUP", or that same string plus
    /// " - Extended Version"/" - 1080p" appended for an alternate cut,
    /// per Jellyfin's multi-version naming convention). `MediaItem
    /// .mediaVersions` diffs this against the item's other sources to
    /// recover a filename-derived edition name (see its
    /// `canonicalSourceName`/`editionLabel`), and falls back to using it
    /// as a raw label only when no such relationship is found; everywhere
    /// else, prefer a friendlier derived string over this.
    var name: String?
    var path: String?
    var container: String?
    var isRemote: Bool?
    var supportsDirectPlay: Bool?
    var runTimeTicks: Int64?
    /// Overall bitrate in bits/sec, for the Details tab's summary row.
    var bitrate: Int?
    /// File size in bytes, for the Details tab's summary row.
    var size: Int64?
    var mediaStreams: [MediaStream]?
}

struct MediaStream: Codable, Identifiable, Hashable {
    var index: Int
    var type: String
    var codec: String?
    var language: String?
    /// The raw embedded stream title (e.g. "Commentary", "Audio
    /// Description"), distinct from the server-computed `displayTitle`.
    var title: String?
    var displayTitle: String?
    var isDefault: Bool?
    var isForced: Bool?
    var isExternal: Bool?
    /// Server-detected, primarily for subtitle streams (SDH/closed-caption
    /// naming conventions); occasionally set for an accessible audio track
    /// too. One of a few signals `MediaItem.metadataBadges` checks for "AD".
    var isHearingImpaired: Bool?

    // Video-specific — used to build the Details tab's resolution/dynamic
    // range rows. `nil` for audio/subtitle streams.
    var width: Int?
    var height: Int?
    var profile: String?
    /// Simple SDR/HDR classification.
    var videoRange: String?
    /// More specific than `videoRange` when present (e.g. "DOVI",
    /// "DOVIWithHDR10", "HDR10", "HLG") — preferred when available.
    var videoRangeType: String?
    /// The stream's actual frame rate (e.g. `23.976`), as measured from the
    /// file — preferred over `averageFrameRate` (a coarser, container-level
    /// figure) when both are present. Either can be missing depending on how
    /// the file was probed server-side.
    var realFrameRate: Double?
    var averageFrameRate: Double?
    /// This stream's own bitrate in bits/sec, as opposed to
    /// `MediaSource.bitrate`, which covers the whole container. Used by the
    /// download path to cap a transcode against the source's *video*
    /// bitrate rather than one inflated by however many audio tracks the
    /// file carries. Not always populated — an older library item or a
    /// container the server couldn't fully probe can leave it `nil`.
    var bitRate: Int?

    // Audio-specific.
    var channelLayout: String?
    /// Server-detected spatial audio format ("None"/"DolbyAtmos"/"DTSX") —
    /// more reliable than text-matching the codec/title for Atmos.
    var audioSpatialFormat: String?

    var id: Int { index }
}

struct PlaybackProgressRequest: Encodable {
    var itemId: String
    var positionTicks: Int64
    var isPaused: Bool = false
    /// Which version is actually playing — the one `PlaybackInfoRequest`
    /// resolved to in `PlayerViewModel.start()`, not necessarily what the
    /// caller originally requested (a requested id that doesn't match any
    /// of the item's sources falls back to the server's default). Lets the
    /// server's active-session bookkeeping reflect the real file being
    /// streamed.
    var mediaSourceId: String?
    /// Set only by `DownloadManager`'s transcode keep-alive ping — see
    /// `JellyfinAPIClient.pingDownloadTranscode`'s doc comment. Live
    /// playback never sets this: `reportPlaybackStart`/`reportPlaybackProgress`/
    /// `reportPlaybackStopped` all leave it `nil`, which is fine since those
    /// calls aren't targeting a specific server-side transcode job the way
    /// a download's keep-alive ping needs to.
    var playSessionId: String?
}

/// Body for `JellyfinAPIClient.updateUserData` (`POST
/// /Users/{userId}/Items/{itemId}/UserData`) — a direct write of a user's
/// watched/resume state, unlike `PlaybackProgressRequest` above which is
/// scoped to an active `/Sessions/Playing*` session. Jellyfin's real
/// `UpdateUserItemDataDto` has more fields (`isFavorite`, etc.); only the
/// ones the offline sync path actually needs to write are modeled here.
struct UpdateUserDataRequest: Encodable {
    var playbackPositionTicks: Int64
    var played: Bool
    var playedPercentage: Double
    /// Jellyfin's own `UserItemDataDto.LastPlayedDate` field — without this,
    /// the server stamps its own value as the moment it *receives* this
    /// request, which for the offline-downloads sync path
    /// (`DownloadSyncManager`) can be hours or days after the item was
    /// actually watched. `nil` is omitted from the encoded request body
    /// entirely (Swift's synthesized `Encodable` uses `encodeIfPresent`
    /// for `Optional` properties), leaving the server's existing value
    /// alone rather than clearing it — in practice every current caller is
    /// the offline sync path and always supplies one.
    var lastPlayedDate: Date?
}

/// A currently-active session, as Jellyfin's `/Sessions` endpoint reports
/// it — used only for `PlaybackStatsOverlay`'s "Streaming" section. This is
/// deliberately separate from `PlaybackInfoResponse`: that endpoint
/// negotiates capabilities *before* playback starts, while a transcode's
/// actual live parameters (current bitrate, completion percentage, ...)
/// only exist server-side in the running ffmpeg process, so they're only
/// ever visible through the live session Jellyfin Web's own playback-info
/// panel polls the same way.
struct SessionInfoDto: Codable {
    var id: String?
    var deviceId: String?
    var playState: PlayStateInfoDto?
    /// Present only while `playState.playMethod == "Transcode"`. Confirmed
    /// live (2026-08-27): this populates for a download's plain transcode
    /// stream too, not just real playback — but `PlayState`'s own fields
    /// (`mediaSourceId`, `playMethod`) do NOT, since those are only set via
    /// `/Sessions/Playing`, which downloads never call. Don't try to key
    /// off `PlayState` to identify a download's session — see
    /// `JellyfinAPIClient.currentSession(deviceID:)`'s doc comment for what
    /// actually works instead.
    var transcodingInfo: TranscodingInfoDto?
}

struct PlayStateInfoDto: Codable {
    var mediaSourceId: String?
    /// Jellyfin's own `PlayMethod` enum, as a raw string: `"DirectPlay"`,
    /// `"DirectStream"`, or `"Transcode"`. Dionysus only ever requests a
    /// static (`Static=true`) stream today (`JellyfinAPIClient.streamURL`),
    /// so this should always come back `"DirectStream"`/`"DirectPlay"` — it
    /// starts reflecting real transcodes automatically once transcode
    /// negotiation is implemented, with no changes needed here.
    var playMethod: String?
}

/// The server's live transcode diagnostics for the current session — same
/// fields Jellyfin Web's own "Playback Info" overlay shows.
struct TranscodingInfoDto: Codable {
    var audioCodec: String?
    var videoCodec: String?
    var container: String?
    var isVideoDirect: Bool?
    var isAudioDirect: Bool?
    /// Bits per second.
    var bitrate: Int?
    var framerate: Double?
    var completionPercentage: Double?
    var width: Int?
    var height: Int?
    var audioChannels: Int?
    /// Why the server chose to transcode instead of direct-playing/-streaming
    /// (e.g. `"VideoBitrateNotSupported"`, `"ContainerNotSupported"`) — an
    /// open-ended set of Jellyfin's own reason codes, kept as raw strings
    /// since they're only ever displayed, never branched on.
    var transcodeReasons: [String]?
}

// MARK: - Search

struct SearchHintResult: Codable {
    var searchHints: [SearchHint]
    var totalRecordCount: Int
}

/// A fast "search as you type" match from Jellyfin's dedicated
/// `/Search/Hints` endpoint — distinct from the full `BaseItemDto` results
/// the general-purpose `/Items` search returns, and much lighter (a handful
/// of display fields, not the full item). Fast enough that `SearchView`
/// uses it as its sole results source, not just a typeahead dropdown; kept
/// to just the fields that results list needs.
///
/// `Encodable` only for `MockURLProtocol.encodedJSONResponse`'s benefit in
/// tests — production code only ever decodes this.
struct SearchHint: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var type: BaseItemKind
    var productionYear: Int?
    /// The parent series' name — present only for `.episode` hints.
    var series: String?
    /// Episode number within its season — present only for `.episode`
    /// hints, paired with `parentIndexNumber` to build an "S1:E4"-style
    /// label (`SearchResult`'s doc comment on `subtitle`).
    var indexNumber: Int?
    /// Season number — present only for `.episode` hints. Despite the
    /// generic-sounding name, this is Jellyfin's actual field for it here
    /// (same as `BaseItemDto.parentIndexNumber`).
    var parentIndexNumber: Int?
    var primaryImageTag: String?
    /// A `Thumb`-type image, and the item it belongs to — usually the same
    /// item, but an episode without its own thumb inherits its series' one,
    /// same idea as `BaseItemDto.parentBackdropItemId`.
    var thumbImageTag: String?
    var thumbImageItemId: String?
}
