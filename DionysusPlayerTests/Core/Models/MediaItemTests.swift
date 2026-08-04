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

    // MARK: technicalSummary

    func test_technicalSummary_collectsContainerCodecAudioAndSubtitleCounts() {
        let source = MediaSourceInfo(
            id: "src-1", container: "mkv",
            mediaStreams: [
                MediaStream(index: 0, type: "Video", codec: "hevc"),
                MediaStream(index: 1, type: "Audio", language: "eng"),
                MediaStream(index: 2, type: "Audio", language: "jpn"),
                MediaStream(index: 3, type: "Subtitle"),
                MediaStream(index: 4, type: "Subtitle")
            ]
        )
        let dto = BaseItemDto(id: "movie-1", name: "Arrival", type: .movie, mediaSources: [source])
        let item = MediaItem(dto: dto, images: images)
        XCTAssertEqual(item.technicalSummary, ["MKV", "HEVC", "Audio: eng, jpn", "2 subtitle tracks"])
    }

    func test_technicalSummary_emptyWhenNoMediaSources() {
        XCTAssertEqual(makeMovie().technicalSummary, [])
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
}
