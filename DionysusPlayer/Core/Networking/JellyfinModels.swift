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

// MARK: - Playback

struct PlaybackInfoRequest: Encodable {
    var userId: String
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
    var deliveryUrl: String?
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
