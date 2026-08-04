import XCTest
@testable import Dionysus

/// `MediaItem` is where a lot of Dionysus's small "does this look right on
/// screen" logic lives (year ranges, durations, resume fractions, rail
/// captions). It's pure computation over a `BaseItemDto`, so it's the
/// cheapest, highest-value thing in the app to unit test — no networking,
/// no view hierarchy, just inputs and expected strings/numbers.
final class MediaItemTests: XCTestCase {
    private let images = ImageURLBuilder(baseURL: URL(string: "https://jellyfin.example.com")!, accessToken: "tok")

    private func makeMovie(
        productionYear: Int? = 2019,
        runTimeTicks: Int64? = nil,
        userData: UserItemDataDto? = nil
    ) -> MediaItem {
        let dto = BaseItemDto(id: "movie-1", name: "Arrival", type: .movie, productionYear: productionYear, runTimeTicks: runTimeTicks, userData: userData)
        return MediaItem(dto: dto, images: images)
    }

    private func makeSeries(productionYear: Int? = 2019, endDate: Date? = nil) -> MediaItem {
        let dto = BaseItemDto(id: "series-1", name: "The Wire", type: .series, productionYear: productionYear, endDate: endDate)
        return MediaItem(dto: dto, images: images)
    }

    private func makeEpisode(
        seriesName: String? = "The Wire",
        indexNumber: Int? = 4,
        parentIndexNumber: Int? = 1,
        name: String = "Old Cases"
    ) -> MediaItem {
        let dto = BaseItemDto(
            id: "ep-1", name: name, type: .episode,
            seriesId: "series-1", seriesName: seriesName,
            indexNumber: indexNumber, parentIndexNumber: parentIndexNumber
        )
        return MediaItem(dto: dto, images: images)
    }

    // MARK: yearText

    func test_yearText_movie_isJustTheYear() {
        XCTAssertEqual(makeMovie(productionYear: 2019).yearText, "2019")
    }

    func test_yearText_movie_nilWhenNoProductionYear() {
        XCTAssertNil(makeMovie(productionYear: nil).yearText)
    }

    func test_yearText_series_stillAiring_hasTrailingDash() {
        XCTAssertEqual(makeSeries(productionYear: 2019, endDate: nil).yearText, "2019\u{2013}")
    }

    func test_yearText_series_endedSameYear_isSingleYear() {
        let sameYear = Calendar.current.date(from: DateComponents(year: 2019, month: 6, day: 1))!
        XCTAssertEqual(makeSeries(productionYear: 2019, endDate: sameYear).yearText, "2019")
    }

    func test_yearText_series_endedLaterYear_isRange() {
        let laterYear = Calendar.current.date(from: DateComponents(year: 2021, month: 6, day: 1))!
        XCTAssertEqual(makeSeries(productionYear: 2019, endDate: laterYear).yearText, "2019\u{2013}2021")
    }

    // MARK: durationText

    func test_durationText_underAnHour() {
        XCTAssertEqual(makeMovie(runTimeTicks: 45 * 60 * 10_000_000).durationText, "45m")
    }

    func test_durationText_hoursAndMinutes() {
        XCTAssertEqual(makeMovie(runTimeTicks: (2 * 60 + 15) * 60 * 10_000_000).durationText, "2h 15m")
    }

    func test_durationText_nilWhenMissingOrZero() {
        XCTAssertNil(makeMovie(runTimeTicks: nil).durationText)
        XCTAssertNil(makeMovie(runTimeTicks: 0).durationText)
    }

    // MARK: episodeLabel

    func test_episodeLabel_formatsSeasonAndEpisode() {
        XCTAssertEqual(makeEpisode(indexNumber: 4, parentIndexNumber: 1).episodeLabel, "S1:E4")
    }

    func test_episodeLabel_nilWhenNumberingMissing() {
        XCTAssertNil(makeEpisode(indexNumber: nil).episodeLabel)
        XCTAssertNil(makeEpisode(parentIndexNumber: nil).episodeLabel)
    }

    func test_episodeLabel_nilForNonEpisodeTypes() {
        XCTAssertNil(makeMovie().episodeLabel)
    }

    // MARK: railTitle

    func test_railTitle_episode_usesSeriesName() {
        XCTAssertEqual(makeEpisode(seriesName: "The Wire").railTitle, "The Wire")
    }

    func test_railTitle_episode_fallsBackToOwnNameWhenSeriesNameMissing() {
        XCTAssertEqual(makeEpisode(seriesName: nil, name: "Old Cases").railTitle, "Old Cases")
    }

    func test_railTitle_movie_usesOwnName() {
        XCTAssertEqual(makeMovie().railTitle, "Arrival")
    }

    // MARK: railSubtitle

    func test_railSubtitle_movie_joinsYearAndDuration() {
        let item = makeMovie(productionYear: 2019, runTimeTicks: 90 * 60 * 10_000_000)
        XCTAssertEqual(item.railSubtitle, "2019 \u{00B7} 1h 30m")
    }

    func test_railSubtitle_movie_yearOnly() {
        let item = makeMovie(productionYear: 2019, runTimeTicks: nil)
        XCTAssertEqual(item.railSubtitle, "2019")
    }

    func test_railSubtitle_movie_nilWhenNeitherAvailable() {
        let item = makeMovie(productionYear: nil, runTimeTicks: nil)
        XCTAssertNil(item.railSubtitle)
    }

    func test_railSubtitle_episode_withNumbering() {
        let item = makeEpisode(indexNumber: 4, parentIndexNumber: 1, name: "Old Cases")
        XCTAssertEqual(item.railSubtitle, "S1:E4 \u{00B7} Old Cases")
    }

    func test_railSubtitle_episode_withoutNumberingFallsBackToName() {
        let item = makeEpisode(indexNumber: nil, name: "Old Cases")
        XCTAssertEqual(item.railSubtitle, "Old Cases")
    }

    func test_railSubtitle_series_isYearText() {
        let item = makeSeries(productionYear: 2019, endDate: nil)
        XCTAssertEqual(item.railSubtitle, "2019\u{2013}")
    }

    // MARK: resumePositionSeconds / playedFraction / isPlayed / isPartWatched

    func test_resumePositionSeconds_convertsTicksToSeconds() {
        let userData = UserItemDataDto(playbackPositionTicks: 30 * 10_000_000)
        XCTAssertEqual(makeMovie(userData: userData).resumePositionSeconds, 30)
    }

    func test_resumePositionSeconds_nilWhenZeroOrMissing() {
        XCTAssertNil(makeMovie(userData: nil).resumePositionSeconds)
        XCTAssertNil(makeMovie(userData: UserItemDataDto(playbackPositionTicks: 0)).resumePositionSeconds)
    }

    func test_playedFraction_prefersServerReportedPercentage() {
        let userData = UserItemDataDto(playbackPositionTicks: 10, playedPercentage: 42)
        XCTAssertEqual(makeMovie(runTimeTicks: 100, userData: userData).playedFraction, 0.42)
    }

    func test_playedFraction_fallsBackToComputedRatioWhenPercentageMissing() {
        let userData = UserItemDataDto(playbackPositionTicks: 25)
        let item = makeMovie(runTimeTicks: 100, userData: userData)
        XCTAssertEqual(item.playedFraction, 0.25)
    }

    func test_playedFraction_nilWithoutEnoughData() {
        XCTAssertNil(makeMovie(userData: nil).playedFraction)
    }

    func test_isPlayed_reflectsUserData() {
        XCTAssertTrue(makeMovie(userData: UserItemDataDto(played: true)).isPlayed)
        XCTAssertFalse(makeMovie(userData: UserItemDataDto(played: false)).isPlayed)
        XCTAssertFalse(makeMovie(userData: nil).isPlayed)
    }

    func test_isPartWatched_trueOnlyBetweenZeroAndOneAndNotPlayed() {
        let midway = UserItemDataDto(playedPercentage: 50, played: false)
        XCTAssertTrue(makeMovie(userData: midway).isPartWatched)

        let finished = UserItemDataDto(playedPercentage: 100, played: true)
        XCTAssertFalse(makeMovie(userData: finished).isPartWatched)

        let untouched = UserItemDataDto(playedPercentage: 0, played: false)
        XCTAssertFalse(makeMovie(userData: untouched).isPartWatched)
    }

    // MARK: technicalDetails

    func test_technicalDetails_buildsContainerCodecResolutionAndDynamicRange() {
        let source = MediaSourceInfo(
            id: "src-1", container: "mkv",
            mediaStreams: [
                MediaStream(index: 0, type: "Video", codec: "hevc", width: 3840, height: 2160, videoRangeType: "DOVI")
            ]
        )
        let dto = BaseItemDto(id: "movie-1", name: "Arrival", type: .movie, mediaSources: [source])
        let item = MediaItem(dto: dto, images: images)
        let details = item.technicalDetails
        XCTAssertEqual(details?.container, "MKV")
        XCTAssertEqual(details?.videoCodec, "H.265 (HEVC)")
        XCTAssertEqual(details?.resolution, "3840\u{00D7}2160 (4K)")
        XCTAssertEqual(details?.dynamicRange, "Dolby Vision")
    }

    /// A letterboxed, very-wide-aspect release (e.g. 2.39:1) has a reduced
    /// height for a genuinely 4K-width source — classifying by height would
    /// misidentify this as 1440p or lower.
    func test_technicalDetails_resolutionClassifiesByWidthNotHeightForLetterboxedVideo() {
        let source = MediaSourceInfo(mediaStreams: [MediaStream(index: 0, type: "Video", width: 3840, height: 1606)])
        let dto = BaseItemDto(id: "movie-1", name: "Arrival", type: .movie, mediaSources: [source])
        XCTAssertEqual(MediaItem(dto: dto, images: images).technicalDetails?.resolution, "3840\u{00D7}1606 (4K)")
    }

    func test_technicalDetails_dolbyVisionWithHDR10PlusLayer() {
        let source = MediaSourceInfo(mediaStreams: [MediaStream(index: 0, type: "Video", videoRangeType: "DOVIWithHDR10Plus")])
        let dto = BaseItemDto(id: "movie-1", name: "Arrival", type: .movie, mediaSources: [source])
        XCTAssertEqual(MediaItem(dto: dto, images: images).technicalDetails?.dynamicRange, "Dolby Vision \u{00B7} HDR10+")
    }

    func test_technicalDetails_fallsBackFromVideoRangeTypeToVideoRange() {
        let source = MediaSourceInfo(mediaStreams: [MediaStream(index: 0, type: "Video", videoRange: "HDR")])
        let dto = BaseItemDto(id: "movie-1", name: "Arrival", type: .movie, mediaSources: [source])
        XCTAssertEqual(MediaItem(dto: dto, images: images).technicalDetails?.dynamicRange, "HDR")
    }

    func test_technicalDetails_omitsUnknownDynamicRange() {
        let source = MediaSourceInfo(mediaStreams: [MediaStream(index: 0, type: "Video", videoRangeType: "Unknown")])
        let dto = BaseItemDto(id: "movie-1", name: "Arrival", type: .movie, mediaSources: [source])
        XCTAssertNil(MediaItem(dto: dto, images: images).technicalDetails?.dynamicRange)
    }

    func test_technicalDetails_audioAndSubtitleTracksPreferDisplayTitle() {
        let source = MediaSourceInfo(mediaStreams: [
            MediaStream(index: 0, type: "Video"),
            MediaStream(index: 1, type: "Audio", language: "eng", displayTitle: "English (AAC 5.1)"),
            MediaStream(index: 2, type: "Audio", codec: "aac"), // no displayTitle -> falls back
            MediaStream(index: 3, type: "Subtitle", displayTitle: "English (SRT - Forced)")
        ])
        let dto = BaseItemDto(id: "movie-1", name: "Arrival", type: .movie, mediaSources: [source])
        let details = MediaItem(dto: dto, images: images).technicalDetails
        XCTAssertEqual(details?.audioTracks, ["English (AAC 5.1)", "AAC"])
        XCTAssertEqual(details?.subtitleTracks, ["English (SRT - Forced)"])
    }

    func test_technicalDetails_includesBitrateAndFileSize() {
        let source = MediaSourceInfo(bitrate: 8_500_000, size: 4_200_000_000, mediaStreams: [])
        let dto = BaseItemDto(id: "movie-1", name: "Arrival", type: .movie, mediaSources: [source])
        let details = MediaItem(dto: dto, images: images).technicalDetails
        XCTAssertEqual(details?.bitrate, "8.5 Mbps")
        XCTAssertEqual(details?.fileSize, ByteCountFormatter.string(fromByteCount: 4_200_000_000, countStyle: .file))
    }

    func test_technicalDetails_nilWhenNoMediaSources() {
        XCTAssertNil(makeMovie().technicalDetails)
    }

    // MARK: cast

    func test_cast_actorUsesRoleAsCharacterName() {
        let person = BaseItemPerson(id: "p1", name: "Timothée Chalamet", role: "Paul Atreides", type: "Actor")
        let dto = BaseItemDto(id: "movie-1", name: "Dune", type: .movie, people: [person])
        XCTAssertEqual(MediaItem(dto: dto, images: images).cast, [
            CastMember(id: "p1", name: "Timothée Chalamet", role: "Paul Atreides", imageURL: nil)
        ])
    }

    func test_cast_crewFallsBackToJobTitleWhenNoRole() {
        let person = BaseItemPerson(id: "p2", name: "Denis Villeneuve", role: nil, type: "Director")
        let dto = BaseItemDto(id: "movie-1", name: "Dune", type: .movie, people: [person])
        XCTAssertEqual(MediaItem(dto: dto, images: images).cast.first?.role, "Director")
    }

    func test_cast_buildsImageURLWhenTagPresent() {
        let person = BaseItemPerson(id: "p1", name: "Timothée Chalamet", primaryImageTag: "tag123")
        let dto = BaseItemDto(id: "movie-1", name: "Dune", type: .movie, people: [person])
        let url = MediaItem(dto: dto, images: images).cast.first?.imageURL
        XCTAssertNotNil(url)
        XCTAssertTrue(url!.absoluteString.contains("Items/p1/Images/Primary"))
        XCTAssertTrue(url!.absoluteString.contains("tag=tag123"))
    }

    func test_cast_emptyWhenNoPeople() {
        XCTAssertEqual(makeMovie().cast, [])
    }

    // MARK: image URLs

    func test_primaryImageURL_includesTagAndToken() {
        let dto = BaseItemDto(id: "movie-1", name: "Arrival", type: .movie, imageTags: ["Primary": "abc123"])
        let item = MediaItem(dto: dto, images: images)
        let url = item.primaryImageURL
        XCTAssertNotNil(url)
        XCTAssertTrue(url!.absoluteString.contains("Items/movie-1/Images/Primary"))
        XCTAssertTrue(url!.absoluteString.contains("tag=abc123"))
        XCTAssertTrue(url!.absoluteString.contains("ApiKey=tok"))
    }

    func test_backdropImageURL_fallsBackToParentBackdropWhenOwnMissing() {
        let dto = BaseItemDto(
            id: "ep-1", name: "Old Cases", type: .episode,
            parentBackdropItemId: "series-1", parentBackdropImageTags: ["zzz"]
        )
        let item = MediaItem(dto: dto, images: images)
        let url = item.backdropImageURL
        XCTAssertNotNil(url)
        XCTAssertTrue(url!.absoluteString.contains("Items/series-1/Images/Backdrop"))
        XCTAssertTrue(url!.absoluteString.contains("tag=zzz"))
    }

    func test_backdropImageURL_nilWhenNoBackdropAvailable() {
        XCTAssertNil(makeMovie().backdropImageURL)
    }

    /// Mirrors `backdropImageURL`'s fallback — an episode without its own
    /// logo should show its Season's (or, if that's also missing, its
    /// Series') logo rather than nothing. Jellyfin resolves which ancestor
    /// actually has one server-side via `parentLogoItemId`/
    /// `parentLogoImageTag`, so this only needs to prefer "own" over that.
    func test_logoImageURL_usesOwnLogoWhenPresent() {
        let dto = BaseItemDto(id: "series-1", name: "The Wire", type: .series, imageTags: ["Logo": "own-logo-tag"])
        let item = MediaItem(dto: dto, images: images)
        let url = item.logoImageURL
        XCTAssertNotNil(url)
        XCTAssertTrue(url!.absoluteString.contains("Items/series-1/Images/Logo"))
        XCTAssertTrue(url!.absoluteString.contains("tag=own-logo-tag"))
    }

    func test_logoImageURL_fallsBackToParentLogoWhenOwnMissing() {
        let dto = BaseItemDto(
            id: "ep-1", name: "Old Cases", type: .episode,
            parentLogoItemId: "season-1", parentLogoImageTag: "season-logo-tag"
        )
        let item = MediaItem(dto: dto, images: images)
        let url = item.logoImageURL
        XCTAssertNotNil(url)
        XCTAssertTrue(url!.absoluteString.contains("Items/season-1/Images/Logo"), "Should use whichever ancestor the server resolved (Season or Series), not hardcode one")
        XCTAssertTrue(url!.absoluteString.contains("tag=season-logo-tag"))
    }

    func test_logoImageURL_prefersOwnLogoOverParent() {
        let dto = BaseItemDto(
            id: "ep-1", name: "Old Cases", type: .episode,
            imageTags: ["Logo": "own-logo-tag"],
            parentLogoItemId: "season-1", parentLogoImageTag: "season-logo-tag"
        )
        let item = MediaItem(dto: dto, images: images)
        XCTAssertTrue(item.logoImageURL!.absoluteString.contains("tag=own-logo-tag"))
    }

    func test_logoImageURL_nilWhenNoLogoAnywhereInHierarchy() {
        XCTAssertNil(makeMovie().logoImageURL)
    }
}
