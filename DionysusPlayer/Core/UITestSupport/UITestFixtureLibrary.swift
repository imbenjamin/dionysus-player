#if DEBUG
import Foundation

/// The deterministic catalogue `UITestStubURLProtocol` serves.
///
/// Built as `BaseItemDto` values and encoded with the app's own
/// `JellyfinJSON.encoder` rather than checked in as raw JSON. That trade is
/// deliberate: hand-written JSON files would be closer to a real server's
/// wire format, but they rot silently — a DTO gains a field and nothing
/// fails until a test does, confusingly. Constructing the DTOs makes a shape
/// change a *compile* error, and the shared encoder guarantees the bytes on
/// the wire are exactly what the shared decoder expects (PascalCase keys,
/// ISO-8601 dates).
///
/// What this deliberately does not cover is wire-format fidelity — an
/// unexpected shape from a real Jellyfin. That belongs to the unit suite's
/// raw-JSON fixtures (`MockURLProtocol`), which test decoding; these fixtures
/// exist to give the *UI* stable data to render.
enum UITestFixtureLibrary {
    // MARK: - Identity

    // Sourced from `UITestFixtureIdentity`, which is compiled into the UI
    // test target too — the tests and the stub have to agree on these, and a
    // second copy of the list is exactly how they would stop agreeing.
    static let moviesLibraryID = UITestFixtureIdentity.moviesLibraryID
    static let showsLibraryID = UITestFixtureIdentity.showsLibraryID
    static let boxSetsLibraryID = UITestFixtureIdentity.boxSetsLibraryID
    static let playlistsLibraryID = UITestFixtureIdentity.playlistsLibraryID

    static let seriesID = UITestFixtureIdentity.seriesID
    static let boxSetID = UITestFixtureIdentity.boxSetID
    static let playlistID = UITestFixtureIdentity.playlistID

    // MARK: - Libraries

    static let libraries: [BaseItemDto] = [
        library(id: moviesLibraryID, name: "Movies", collectionType: JellyfinCollectionType.movies),
        library(id: showsLibraryID, name: "TV Shows", collectionType: JellyfinCollectionType.tvShows),
        library(id: boxSetsLibraryID, name: "Collections", collectionType: JellyfinCollectionType.boxSets),
        library(id: playlistsLibraryID, name: "Playlists", collectionType: JellyfinCollectionType.playlists)
    ]

    // MARK: - Movies

    /// Twelve movies spanning four genres, three studios and three decades,
    /// with a deliberate spread of watched/favourite state. The spread is
    /// what makes `CollectionGridView`'s five cascading facets testable: any
    /// combination the UI offers has to leave at least one result, and that
    /// guarantee is only meaningful over data with real cardinality.
    static let movies: [BaseItemDto] = {
        let specs: [(title: String, year: Int, genre: String, studio: String, watched: Bool, favorite: Bool)] = [
            ("The Quiet Ascent",      2021, "Drama",  "Aurora Pictures",    false, true),
            ("Signal Fire",           2019, "Sci-Fi", "Northlight Studios", true,  false),
            ("Harbour Lights",        2018, "Drama",  "Vantage Film",       false, false),
            ("Iron Meridian",         2016, "Action", "Aurora Pictures",    true,  true),
            ("The Longest Winter",    2014, "Drama",  "Northlight Studios", false, false),
            ("Paper Aeroplanes",      2012, "Comedy", "Vantage Film",       true,  false),
            ("Orbital Decay",         2009, "Sci-Fi", "Aurora Pictures",    false, false),
            ("Second Sunrise",        2007, "Drama",  "Northlight Studios", false, true),
            ("The Cartographer",      2004, "Drama",  "Vantage Film",       true,  false),
            ("Nightshift",            2001, "Action", "Aurora Pictures",    false, false),
            ("Small Mercies",         1998, "Comedy", "Northlight Studios", true,  false),
            ("The Salt Road",         1994, "Action", "Vantage Film",       false, false)
        ]

        return specs.enumerated().map { index, spec in
            var item = base(
                id: UITestFixtureIdentity.movieID(index + 1),
                name: spec.title,
                type: .movie
            )
            item.overview = "\(spec.title) is a \(spec.genre.lowercased()) feature produced by \(spec.studio)."
            item.taglines = ["Every road leads somewhere."]
            item.productionYear = spec.year
            item.premiereDate = date(year: spec.year, month: 6, day: 1)
            item.communityRating = 6.0 + Double(index % 4) * 0.7
            item.officialRating = index % 3 == 0 ? "PG-13" : "15"
            item.genres = [spec.genre]
            item.studios = [NameGuidPair(name: spec.studio, id: studioID(spec.studio))]
            item.runTimeTicks = ticks(minutes: 92 + index * 3)
            item.userData = UserItemDataDto(
                playbackPositionTicks: index == 1 ? ticks(minutes: 20) : 0,
                playedPercentage: index == 1 ? 21 : (spec.watched ? 100 : 0),
                played: spec.watched,
                isFavorite: spec.favorite
            )
            item.mediaSources = [mediaSource(for: item)]
            item.people = cast(seed: index)
            item.chapters = chapters(runtimeMinutes: 92 + index * 3)
            return item
        }
    }()

    // MARK: - Series, seasons, episodes

    static let series: BaseItemDto = {
        var item = base(id: seriesID, name: UITestFixtureIdentity.seriesName, type: .series)
        item.overview = "A research crew overwinters at the edge of the ice."
        item.productionYear = 2020
        item.premiereDate = date(year: 2020, month: 1, day: 12)
        item.communityRating = 8.4
        item.officialRating = "15"
        item.genres = ["Drama", "Sci-Fi"]
        item.studios = [NameGuidPair(name: "Northlight Studios", id: studioID("Northlight Studios"))]
        item.childCount = 2
        item.userData = UserItemDataDto(playbackPositionTicks: 0, playedPercentage: 0, played: false, isFavorite: false)
        return item
    }()

    static let seasons: [BaseItemDto] = (1...2).map { number in
        var item = base(id: "season-\(number)", name: "Season \(number)", type: .season)
        item.seriesId = seriesID
        item.seriesName = UITestFixtureIdentity.seriesName
        item.indexNumber = number
        item.childCount = 3
        item.productionYear = 2019 + number
        item.userData = UserItemDataDto(playbackPositionTicks: 0, playedPercentage: 0, played: false, isFavorite: false)
        return item
    }

    static let episodes: [BaseItemDto] = seasons.flatMap { season in
        (1...3).map { number in
            let seasonNumber = season.indexNumber ?? 1
            var item = base(
                id: "episode-s\(seasonNumber)e\(number)",
                name: "Episode \(number)",
                type: .episode
            )
            item.overview = "Season \(seasonNumber), episode \(number)."
            item.seriesId = seriesID
            item.seriesName = UITestFixtureIdentity.seriesName
            item.seasonId = season.id
            item.seasonName = season.name
            item.indexNumber = number
            item.parentIndexNumber = seasonNumber
            item.runTimeTicks = ticks(minutes: 48)
            item.premiereDate = date(year: 2019 + seasonNumber, month: number, day: 5)
            // Season 1 episode 1 is part-watched, so Continue Watching and
            // Next Up both have something real to show.
            let isPartWatched = seasonNumber == 1 && number == 1
            item.userData = UserItemDataDto(
                playbackPositionTicks: isPartWatched ? ticks(minutes: 12) : 0,
                playedPercentage: isPartWatched ? 25 : 0,
                played: false,
                isFavorite: false
            )
            item.mediaSources = [mediaSource(for: item)]
            item.chapters = chapters(runtimeMinutes: 48)
            return item
        }
    }

    // MARK: - Box set and playlist

    static let boxSet: BaseItemDto = {
        var item = base(id: boxSetID, name: "The Aurora Trilogy", type: .boxSet)
        item.overview = "Three features from Aurora Pictures."
        item.childCount = 3
        item.userData = UserItemDataDto(playbackPositionTicks: 0, playedPercentage: 0, played: false, isFavorite: false)
        return item
    }()

    /// Members of `boxSet`, in the order the detail screen should list them.
    static var boxSetMembers: [BaseItemDto] {
        movies.filter { $0.studios?.first?.name == "Aurora Pictures" }
    }

    static let playlist: BaseItemDto = {
        var item = base(id: playlistID, name: "Weekend Watchlist", type: .playlist)
        item.overview = "A short queue for testing sequential Up Next."
        item.childCount = 4
        item.mediaType = "Video"
        item.userData = UserItemDataDto(playbackPositionTicks: 0, playedPercentage: 0, played: false, isFavorite: false)
        return item
    }()

    static var playlistMembers: [BaseItemDto] {
        Array(movies.prefix(3)) + [episodes[0]]
    }

    // MARK: - Flat lookup

    /// Every addressable item, keyed by id — what `/Users/{id}/Items/{itemID}`
    /// resolves against.
    static let allItems: [String: BaseItemDto] = {
        let everything = libraries + movies + [series] + seasons + episodes + [boxSet, playlist]
        return Dictionary(uniqueKeysWithValues: everything.map { ($0.id, $0) })
    }()

    /// Everything a recursive, unscoped browse should be able to return —
    /// libraries excluded, since Jellyfin doesn't return views from `/Items`.
    static let browsableItems: [BaseItemDto] = movies + [series] + seasons + episodes + [boxSet, playlist]

    // MARK: - Server identity

    static var publicSystemInfo: PublicSystemInfo {
        PublicSystemInfo(
            localAddress: UITestConfiguration.stubServerURL.absoluteString,
            serverName: UITestConfiguration.stubServerName,
            version: "10.10.3",
            productName: "Jellyfin Server",
            id: "uitest-server-0001"
        )
    }

    static var authenticationResult: AuthenticationResult {
        AuthenticationResult(
            user: user,
            accessToken: UITestConfiguration.stubAccessToken,
            serverId: "uitest-server-0001"
        )
    }

    static var user: UserDto {
        UserDto(
            id: UITestConfiguration.stubUserID,
            name: UITestConfiguration.stubUsername,
            hasPassword: true,
            primaryImageTag: "avatar-tag"
        )
    }

    // MARK: - Construction helpers

    private static func base(id: String, name: String, type: BaseItemKind) -> BaseItemDto {
        var item = BaseItemDto(id: id, name: name, type: type)
        // Every tile in the app asks `ImageURLBuilder` for artwork keyed off
        // these tags; the stub answers each image request with a generated
        // PNG, so populating them exercises the real image path rather than
        // parking every tile on `MediaPlaceholderBox`.
        item.imageTags = ["Primary": "\(id)-primary", "Thumb": "\(id)-thumb", "Logo": "\(id)-logo"]
        item.backdropImageTags = ["\(id)-backdrop"]
        item.mediaType = "Video"
        return item
    }

    private static func library(id: String, name: String, collectionType: String) -> BaseItemDto {
        var item = BaseItemDto(id: id, name: name, type: .collectionFolder)
        item.collectionType = collectionType
        item.imageTags = ["Primary": "\(id)-primary"]
        return item
    }

    /// Stable across launches, unlike `hashValue` — Swift seeds string
    /// hashing per-process, so a hash-derived id would differ between the
    /// app and any test that tried to predict it.
    private static func studioID(_ name: String) -> String {
        "studio-" + name.lowercased().replacingOccurrences(of: " ", with: "-")
    }

    private static func mediaSource(for item: BaseItemDto) -> MediaSourceInfo {
        var source = MediaSourceInfo(id: "source-\(item.id)")
        source.name = item.name
        source.container = "mkv"
        source.isRemote = false
        source.supportsDirectPlay = true
        source.supportsDirectStream = true
        source.supportsTranscoding = true
        source.runTimeTicks = item.runTimeTicks
        source.bitrate = 18_000_000
        source.size = 6_400_000_000
        source.mediaStreams = [
            videoStream(),
            audioStream(index: 1, language: "eng", codec: "eac3", channels: 6, isDefault: true),
            audioStream(index: 2, language: "fra", codec: "aac", channels: 2, isDefault: false),
            subtitleStream(index: 3, language: "eng", isForced: false),
            subtitleStream(index: 4, language: "eng", isForced: true)
        ]
        return source
    }

    private static func videoStream() -> MediaStream {
        var stream = MediaStream(index: 0, type: "Video")
        stream.codec = "hevc"
        stream.width = 3840
        stream.height = 2160
        stream.profile = "Main 10"
        stream.videoRange = "HDR"
        stream.videoRangeType = "HDR10"
        stream.realFrameRate = 23.976
        stream.averageFrameRate = 23.976
        stream.bitRate = 16_000_000
        stream.isDefault = true
        return stream
    }

    private static func audioStream(index: Int, language: String, codec: String, channels: Int, isDefault: Bool) -> MediaStream {
        var stream = MediaStream(index: index, type: "Audio")
        stream.codec = codec
        stream.language = language
        stream.channelLayout = channels == 6 ? "5.1" : "stereo"
        stream.bitRate = channels == 6 ? 768_000 : 192_000
        stream.isDefault = isDefault
        stream.displayTitle = "\(language.uppercased()) \(codec.uppercased())"
        return stream
    }

    private static func subtitleStream(index: Int, language: String, isForced: Bool) -> MediaStream {
        var stream = MediaStream(index: index, type: "Subtitle")
        stream.codec = "subrip"
        stream.language = language
        stream.isForced = isForced
        stream.isExternal = false
        stream.displayTitle = isForced ? "English (Forced)" : "English"
        return stream
    }

    private static func cast(seed: Int) -> [BaseItemPerson] {
        let names = ["Mara Ellis", "Julian Frost", "Nadia Okonkwo", "Peter Vance", "Rosa Lindqvist"]
        return (0..<3).map { offset in
            let name = names[(seed + offset) % names.count]
            let slug = name.lowercased().replacingOccurrences(of: " ", with: "-")
            return BaseItemPerson(
                id: "person-\(slug)",
                name: name,
                role: offset == 2 ? nil : "Character \(offset + 1)",
                type: offset == 2 ? "Director" : "Actor",
                primaryImageTag: "\(slug)-primary"
            )
        }
    }

    /// Four evenly-spaced chapters. `MediaItem.chapters` requires 2+ before
    /// any chapter UI appears at all, so anything smaller would silently
    /// disable the rail, the picker and the scrubber snapping.
    private static func chapters(runtimeMinutes: Int) -> [ChapterInfoDto] {
        (0..<4).map { index in
            ChapterInfoDto(
                startPositionTicks: ticks(minutes: runtimeMinutes * index / 4),
                name: "Chapter \(index + 1)",
                imageTag: "chapter-\(index)"
            )
        }
    }

    static func ticks(minutes: Int) -> Int64 { Int64(minutes) * 60 * 10_000_000 }

    private static func date(year: Int, month: Int, day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components) ?? .distantPast
    }
}
#endif
