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

// `Codable` rather than `Encodable`: the app only encodes this, but
// `UITestStubURLProtocol` decodes it from the request body to check the posted
// password, which is what makes a bad-credentials login journey simulable.
struct AuthenticateByNameRequest: Codable {
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

/// What a `BaseItemDto` represents. Jellyfin's `Type` is open-ended — plugins
/// add their own — so unknown values decode to `.unknown` rather than failing.
enum BaseItemKind: String, Codable {
    case movie = "Movie"
    case series = "Series"
    case season = "Season"
    case episode = "Episode"
    case boxSet = "BoxSet"
    case collectionFolder = "CollectionFolder"
    case folder = "Folder"
    case playlist = "Playlist"
    // AUDIO SUPPRESSION: these five decode audio types explicitly rather than
    // letting them fall to `.unknown`, which routes into `MovieDetailView`'s
    // default branch. Keep them once audio playback lands, repointed at a real
    // audio path. `MusicVideo` is excluded: it is a real video file that plays
    // fine through the `.unknown` fallback.
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

    /// The SF Symbol `MediaPlaceholderBox` shows while this kind's artwork
    /// loads or after it fails — representative of the content type, so a
    /// show's placeholder looks like a TV rather than a generic photo icon.
    ///
    /// `.playlist` takes `"list.triangle"`, Apple's symbol for a playback queue,
    /// rather than a music glyph: a Jellyfin playlist can hold any media type.
    /// The music cases are unreachable under the audio-suppression policy, but
    /// the switch stays exhaustive.
    var placeholderSystemImage: String {
        switch self {
        case .movie: "film"
        case .series, .season: "tv"
        case .episode: "play.tv"
        case .boxSet: "square.stack.3d.down.right"
        case .collectionFolder, .folder: "folder"
        case .playlist: "list.triangle"
        case .audio, .audioBook, .musicAlbum, .musicArtist, .musicGenre: "music.note"
        case .unknown: "photo"
        }
    }
}

struct BaseItemDto: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var overview: String?
    /// Marketing taglines. Modelled as an array but populated with at most one
    /// entry; requested only via `Fields=Taglines`.
    var taglines: [String]?
    var type: BaseItemKind

    var productionYear: Int?
    var endDate: Date?
    var premiereDate: Date?

    var communityRating: Double?
    var officialRating: String?
    var genres: [String]?
    /// Name and id pairs, unlike `genres`' plain strings. Used by
    /// `CollectionGridView`'s Studios filter.
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
    /// Total descendants of a folder-like item: every episode across every
    /// season for a Series, just its own for a Season. Needed separately
    /// because `childCount` counts seasons on a Series. Populated only via
    /// `Fields=RecursiveItemCount`.
    var recursiveItemCount: Int?

    /// Whether this user may delete this item, computed server-side and
    /// populated only via `Fields=CanDelete`.
    ///
    /// Taken from the server rather than derived from policy flags.
    /// `BaseItem.CanDelete(user)` is `IsFileProtocol` and either the global
    /// `EnableContentDeletion` or the item's collection folder appearing in the
    /// user's `EnableContentDeletionFromFolders`. Checking
    /// `EnableContentDeletion` alone would hide the affordance from users
    /// granted delete on specific folders and offer it for undeletable items.
    /// This flag comes from the same predicate `DELETE /Items/{id}` enforces.
    var canDelete: Bool?

    /// This entry's identity within one playlist, distinct from `id`, which
    /// identifies the media item and is not unique per row — the same item can
    /// appear twice. Populated only by `GET /Playlists/{id}/Items`, and required
    /// by `removePlaylistItems`, which removes by this id: removing the second
    /// copy of a duplicated item by the shared `id` would be ambiguous.
    var playlistItemId: String?

    // Images
    var imageTags: [String: String]?
    var backdropImageTags: [String]?
    /// Scrub-preview tile sheets, keyed by `MediaSourceInfo.id` then by tile
    /// width in pixels as a string. Populated only via `Fields=Trickplay`, and
    /// empty for content not yet scanned. `TrickplayMath` maps a scrub position
    /// onto a tile.
    var trickplay: [String: [String: TrickplayInfo]]?
    var parentBackdropItemId: String?
    var parentBackdropImageTags: [String]?
    /// The nearest ancestor with a logo — an episode's Season, else its Series
    /// — resolved server-side, as `parentBackdropItemId` is.
    var parentLogoItemId: String?
    var parentLogoImageTag: String?

    var userData: UserItemDataDto?

    /// Populated via `Fields=MediaSources`; drives the detail page's technical
    /// info and the playback URL.
    var mediaSources: [MediaSourceInfo]?

    /// Populated via `Fields=People`; the detail page's Cast & Crew tab.
    var people: [BaseItemPerson]?

    /// Named position markers, populated only via `Fields=Chapters`. Empty, or
    /// a single dummy entry, for content with no real chapter data — which is
    /// why `MediaItem.chapters` requires two before surfacing any chapter UI.
    ///
    /// Unrelated to `MediaSegmentDto`, Jellyfin's skippable Intro/Outro feature:
    /// chapters are navigational and never auto-skipped.
    var chapters: [ChapterInfoDto]?

    /// Present on the library views `/Users/{id}/Views` returns; scopes Home's
    /// rails.
    var collectionType: String?
    /// Coarse content classification: `"Video"`, `"Audio"`, `"Photo"`,
    /// `"Book"`, or the `"Unknown"` default, which includes the folder-like
    /// `MusicAlbum`/`MusicArtist` types — `isAudioContent` keys off `type` for
    /// those. Reliable for leaf `Audio` items and for playlists, whose
    /// `MediaType` reflects their content.
    var mediaType: String?
}

/// The `CollectionType` values `/Users/{id}/Views` reports, as constants rather
/// than string literals repeated at each call site.
enum JellyfinCollectionType {
    static let movies = "movies"
    static let tvShows = "tvshows"
    static let boxSets = "boxsets"
    static let playlists = "playlists"
    // AUDIO SUPPRESSION: used only by `MediaItem.isAudioLibrary`, to hide a
    // Music library from Home. Delete once browsing one is supported.
    static let music = "music"
}

/// AUDIO SUPPRESSION: the single source of truth for content this app can't
/// play yet. Every suppression check — Home rails, detail screen, playback,
/// downloads — calls this rather than re-deriving the type logic. Keep it once
/// audio support lands, repointed at an audio player.
extension BaseItemDto {
    var isAudioContent: Bool {
        switch type {
        case .audio, .audioBook, .musicAlbum, .musicArtist, .musicGenre:
            return true
        case .playlist:
            // An empty playlist also reports `MediaType: "Audio"`, the server
            // default with no content to infer from. Over-suppressing one is
            // safer than under-suppressing into a broken Play button.
            return mediaType == "Audio"
        default:
            return false
        }
    }
}

/// One cast or crew credit. `Type` is as open-ended as `BaseItemKind`, and stays
/// a plain string since it is only ever shown as a label.
struct BaseItemPerson: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    /// The character name for an acting credit; usually absent for crew, where
    /// `type` is the meaningful label.
    var role: String?
    var type: String?
    var primaryImageTag: String?
}

/// One entry of `BaseItemDto.chapters`: a named position marker with an optional
/// server-generated still frame.
///
/// A `nil` `imageTag` is the only reliable "no image here" signal —
/// `ImagePath`/`ImageDateModified`, also sent, describe a server-side file path
/// — so `Chapter.imageURL` is built only when it is non-nil. The image route is
/// addressed by the chapter's position in the array rather than any id, which is
/// why `Chapter` carries the enumerated index.
struct ChapterInfoDto: Codable, Equatable {
    /// .NET ticks (10,000,000 per second), same unit as `runTimeTicks`.
    var startPositionTicks: Int64
    /// Usually normalized server-side to "Chapter N" when the source name was
    /// blank or a timestamp; `Chapter.init` still falls back rather than
    /// trusting that.
    var name: String?
    var imageTag: String?
}

/// Jellyfin's generic name-plus-id shape, used for `BaseItemDto.studios`.
struct NameGuidPair: Codable, Hashable {
    var name: String
    var id: String?
}

extension BaseItemDto: Hashable {
    /// Id-only while the synthesized `==` stays structural — the legal
    /// direction for the `Hashable` contract, and what keeps id-keyed lookups
    /// treating one server item as one entry.
    ///
    /// `==` must stay structural: `MediaItem` forwards its equality here, and
    /// SwiftUI uses it to decide whether a view changed. See `MediaItem.==`.
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// One resolution of a server-generated trickplay track: a still every
/// `interval` ms across the runtime, packed row-major into
/// `tileWidth × tileHeight` tile-sheet JPEGs. `TrickplayMath` does the seconds
/// to sheet-and-tile lookup.
struct TrickplayInfo: Codable, Equatable {
    var width: Int
    var height: Int
    var tileWidth: Int
    var tileHeight: Int
    var thumbnailCount: Int
    var interval: Int
    var bandwidth: Int
}

struct UserItemDataDto: Codable, Equatable {
    var playbackPositionTicks: Int64?
    var playedPercentage: Double?
    var played: Bool?
    var isFavorite: Bool?
}

struct BaseItemDtoQueryResult: Codable {
    var items: [BaseItemDto]
    var totalRecordCount: Int
}

// MARK: - Playlists

/// The caller's edit permission on one playlist: a server-computed verdict, the
/// playlist equivalent of `BaseItemDto.canDelete`. `PlaylistDto` never exposes
/// `OwnerUserId`, so this can't be reconstructed locally. An owner always gets
/// `canEdit: true`, a share its real value, and anyone else a 404, which
/// `playlistUserPermissions` maps to `nil`.
struct PlaylistUserPermissions: Codable {
    var userId: String
    var canEdit: Bool
}

/// `GET /Playlists/{id}`. Jellyfin's `PlaylistDto` carries only the playlist's
/// shares, open-access flag and member ids — not `OwnerUserId`, which is why
/// `PlaylistUserPermissions` exists.
///
/// Only `itemIds` is modelled, since that is all `playlistMemberIDs` needs and
/// `Shares` can't answer the ownership question alone. Optional because a
/// playlist with no members omits the key. `Codable` so `UITestStubURLProtocol`
/// can encode one.
struct PlaylistDto: Codable {
    var itemIds: [String]?
}

/// One row in the "Add to Playlist" picker: a playlist this user may edit,
/// paired with what it holds.
///
/// Composed by `editablePlaylists` from two requests per playlist rather than
/// decoded from one response; no endpoint answers both "may I edit this" and
/// "what's in it".
struct EditablePlaylist: Equatable {
    var item: BaseItemDto
    var memberItemIDs: Set<String>
}

/// `POST /Playlists`' body.
///
/// No `CodingKeys` needed: `JellyfinJSON`'s `CodingKeyCasing` uppercases each
/// key's first letter, which matches `CreatePlaylistDto`'s spelling.
///
/// `isPublic` is non-optional, unlike this file's other request-body fields,
/// which rely on `encodeIfPresent` to be omitted. Omitting it is not a safe
/// default: `CreatePlaylistDto.IsPublic` initializes to `true` server-side, so a
/// body without it creates a playlist visible to every user on the server.
///
/// `Codable` so `UITestStubURLProtocol` can decode this body and answer with a
/// playlist of the right name.
struct CreatePlaylistRequest: Codable {
    var name: String
    var ids: [String]
    var userId: String
    var isPublic: Bool
}

/// `POST /Playlists`' response, carrying the new playlist's id and nothing else.
/// `Codable` so the UI-test stub can encode what the app decodes.
struct PlaylistCreationResult: Codable {
    var id: String
}

// MARK: - Media Segments

/// Jellyfin's Media Segments feature: skippable Intro/Outro/Recap/Preview/
/// Commercial ranges. Older servers error on the endpoint, which
/// `PlayerViewModel.loadMediaSegments(for:)` tolerates like any optional lookup.
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
    /// Scopes the response to one of the item's `mediaSources` — the version
    /// picker's choice — or `nil` to let the server pick its default, as in the
    /// common single-version case.
    var mediaSourceId: String?
    /// Non-nil only in "Allow Transcoding" mode (see `DeviceProfileBuilder`). A
    /// `nil` omits the field entirely rather than encoding JSON `null`, leaving
    /// a Direct Play Always request with no profile at all.
    var deviceProfile: DeviceProfile?
    /// Mirrors `DeviceProfile.maxStreamingBitrate`, sent both at the top level
    /// and inside the profile as reference clients do. Non-nil only in "Allow
    /// Transcoding" mode with a `StreamingMaxBitrate` other than `.unlimited`.
    var maxStreamingBitrate: Int?
    var startTimeTicks: Int64?
    var allowVideoStreamCopy: Bool?
    var allowAudioStreamCopy: Bool?
}

struct PlaybackInfoResponse: Codable {
    var mediaSources: [MediaSourceInfo]?
    var playSessionId: String?
    /// Jellyfin's `PlaybackErrorCode`, meaningful only when `mediaSources` comes
    /// back empty — which happens only in "Allow Transcoding" mode, since a
    /// request with no `DeviceProfile` gives the server nothing to reject.
    var errorCode: String?
}

struct MediaSourceInfo: Codable, Identifiable, Equatable {
    var id: String?
    /// Server-computed from the filename, with an edition suffix appended for an
    /// alternate cut per Jellyfin's multi-version naming convention.
    /// `MediaItem.mediaVersions` diffs it against the item's other sources to
    /// recover that edition name, falling back to this raw value only when no
    /// such relationship holds. Prefer a friendlier derived string elsewhere.
    var name: String?
    var path: String?
    var container: String?
    var isRemote: Bool?
    var supportsDirectPlay: Bool?
    /// Advisory only, as `supportsDirectPlay`/`supportsTranscoding` are. Don't
    /// branch on any of the three: `transcodingUrl`'s presence is the verdict.
    var supportsDirectStream: Bool?
    var supportsTranscoding: Bool?
    var runTimeTicks: Int64?
    /// Overall bitrate in bits/sec, for the Details tab's summary row.
    var bitrate: Int?
    /// File size in bytes, for the Details tab's summary row.
    var size: Int64?
    var mediaStreams: [MediaStream]?
    /// A root-relative path and query string, not a full URL; resolve it via
    /// `JellyfinAPIClient.resolveTranscodingURL(_:)`. Populated only in "Allow
    /// Transcoding" mode, and only when the server ruled out direct play.
    ///
    /// Its presence or absence is the whole direct-play-versus-transcode
    /// decision; the three `supports*` flags above are advisory.
    var transcodingUrl: String?
    /// "hls" or "http"; meaningful only alongside `transcodingUrl`.
    var transcodingSubProtocol: String?
    var transcodingContainer: String?
}

struct MediaStream: Codable, Identifiable, Hashable {
    var index: Int
    var type: String
    var codec: String?
    var language: String?
    /// The raw embedded stream title, distinct from the server-computed
    /// `displayTitle`.
    var title: String?
    var displayTitle: String?
    var isDefault: Bool?
    var isForced: Bool?
    var isExternal: Bool?
    /// Server-detected, mostly for subtitle streams following SDH naming
    /// conventions and occasionally for an accessible audio track. One of the
    /// signals `MediaItem.metadataBadges` checks for "AD".
    var isHearingImpaired: Bool?

    // Video-specific, for the Details tab's resolution and dynamic-range rows.
    // `nil` for audio and subtitle streams.
    var width: Int?
    var height: Int?
    var profile: String?
    /// Simple SDR/HDR classification.
    var videoRange: String?
    /// More specific than `videoRange` ("DOVI", "DOVIWithHDR10", "HDR10",
    /// "HLG"), and preferred when present.
    var videoRangeType: String?
    /// The frame rate measured from the file, preferred over the coarser
    /// container-level `averageFrameRate`. Either can be missing, depending on
    /// how the file was probed.
    var realFrameRate: Double?
    var averageFrameRate: Double?
    /// This stream's own bitrate, as opposed to `MediaSource.bitrate`, which
    /// covers the whole container. The download path caps a transcode against
    /// this rather than a figure inflated by the file's audio tracks. `nil` for
    /// an older library item or a container the server couldn't fully probe.
    var bitRate: Int?

    // Audio-specific.
    var channelLayout: String?
    /// Server-detected spatial format ("None"/"DolbyAtmos"/"DTSX"), more
    /// reliable than text-matching the codec or title for Atmos.
    var audioSpatialFormat: String?

    var id: Int { index }
}

struct PlaybackProgressRequest: Encodable {
    var itemId: String
    var positionTicks: Int64
    var isPaused: Bool = false
    /// The version actually playing, as `PlaybackInfoRequest` resolved it — not
    /// necessarily the one requested, since an unmatched id falls back to the
    /// server's default. Keeps the server's session bookkeeping accurate.
    var mediaSourceId: String?
    /// Set by `DownloadManager`'s transcode keep-alive ping, and by live
    /// playback in "Allow Transcoding" mode:
    /// `PlayerViewModel.activePlaySessionID` flows into the
    /// `reportPlayback*` calls so the server can track and kill the right
    /// transcode job. `nil` in Direct Play Always mode, where no
    /// `DeviceProfile` is sent and the server allocates no job.
    var playSessionId: String?
}

/// Body for `JellyfinAPIClient.updateUserData`: a direct write of watched and
/// resume state, unlike `PlaybackProgressRequest`, which needs an active
/// session. Jellyfin's `UpdateUserItemDataDto` has more fields; only those the
/// offline sync path writes are modelled.
struct UpdateUserDataRequest: Encodable {
    var playbackPositionTicks: Int64
    var played: Bool
    var playedPercentage: Double
    /// Without this the server stamps the moment it receives the request, which
    /// for `DownloadSyncManager` can be days after the item was watched. A `nil`
    /// is omitted from the body entirely, leaving the server's existing value
    /// alone rather than clearing it.
    var lastPlayedDate: Date?
}

/// An active session as `/Sessions` reports it, for `PlaybackStatsOverlay`'s
/// "Streaming" section. Separate from `PlaybackInfoResponse`, which negotiates
/// capabilities before playback: a transcode's live parameters exist only in the
/// running ffmpeg process and are visible only through the live session, which
/// is what Jellyfin Web's own playback-info panel polls.
struct SessionInfoDto: Codable {
    var id: String?
    var deviceId: String?
    var playState: PlayStateInfoDto?
    /// Populates for a download's transcode stream as well as for playback.
    /// `PlayState`'s own fields do not, since they are set only via
    /// `/Sessions/Playing`, which downloads never call — so don't key off
    /// `PlayState` to identify a download's session.
    var transcodingInfo: TranscodingInfoDto?
}

struct PlayStateInfoDto: Codable {
    var mediaSourceId: String?
    /// Jellyfin's `PlayMethod` as a raw string: `"DirectPlay"`,
    /// `"DirectStream"` or `"Transcode"`.
    var playMethod: String?
}

/// Live transcode diagnostics for the current session, the same fields Jellyfin
/// Web's Playback Info overlay shows.
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
    /// Why the server transcoded rather than direct-playing. An open-ended set
    /// of reason codes, kept as raw strings since they are only displayed.
    var transcodeReasons: [String]?
}

// MARK: - Search

struct SearchHintResult: Codable {
    var searchHints: [SearchHint]
    var totalRecordCount: Int
}

/// A search-as-you-type match from `/Search/Hints`: a handful of display fields
/// rather than the full `BaseItemDto` that `/Items` returns. Fast enough that
/// `SearchView` uses it as its sole results source, not just a typeahead.
///
/// `Encodable` for `MockURLProtocol.encodedJSONResponse`; production code only
/// decodes this.
struct SearchHint: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var type: BaseItemKind
    var productionYear: Int?
    /// The parent series' name; `.episode` hints only.
    var series: String?
    /// Episode number within its season; `.episode` hints only, paired with
    /// `parentIndexNumber` to build an "S1:E4" label.
    var indexNumber: Int?
    /// Season number; `.episode` hints only. The generic name is Jellyfin's own,
    /// matching `BaseItemDto.parentIndexNumber`.
    var parentIndexNumber: Int?
    var primaryImageTag: String?
    /// A `Thumb` image and the item it belongs to — usually this item, but an
    /// episode without one inherits its series', as with
    /// `BaseItemDto.parentBackdropItemId`.
    var thumbImageTag: String?
    var thumbImageItemId: String?
}
