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

    var userData: UserItemDataDto?

    /// Only populated when requested via `Fields=MediaSources`; used for the
    /// detail page's technical-info section and to build a playback URL.
    var mediaSources: [MediaSourceInfo]?

    /// Present on library "views" (e.g. `"movies"`, `"tvshows"`, `"boxsets"`)
    /// returned by `/Users/{id}/Views`; used to scope Home's rails.
    var collectionType: String?
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
    var path: String?
    var container: String?
    var isRemote: Bool?
    var supportsDirectPlay: Bool?
    var runTimeTicks: Int64?
    var mediaStreams: [MediaStream]?
}

struct MediaStream: Codable, Identifiable, Hashable {
    var index: Int
    var type: String
    var codec: String?
    var language: String?
    var displayTitle: String?
    var isDefault: Bool?
    var isExternal: Bool?
    var deliveryUrl: String?

    var id: Int { index }
}

struct PlaybackProgressRequest: Encodable {
    var itemId: String
    var positionTicks: Int64
    var isPaused: Bool = false
}
