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

    func test_isFavorite_reflectsUserData() {
        XCTAssertTrue(makeMovie(userData: UserItemDataDto(isFavorite: true)).isFavorite)
        XCTAssertFalse(makeMovie(userData: UserItemDataDto(isFavorite: false)).isFavorite)
        XCTAssertFalse(makeMovie(userData: nil).isFavorite)
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

    // MARK: metadataBadges

    private func makeMovie(mediaSources: [MediaSourceInfo]) -> MediaItem {
        let dto = BaseItemDto(id: "movie-1", name: "Arrival", type: .movie, mediaSources: mediaSources)
        return MediaItem(dto: dto, images: images)
    }

    func test_metadataBadges_4KForUltraHDWidth() {
        let source = MediaSourceInfo(mediaStreams: [MediaStream(index: 0, type: "Video", width: 3840, height: 2160)])
        XCTAssertTrue(makeMovie(mediaSources: [source]).metadataBadges.contains("4K"))
    }

    func test_metadataBadges_HDForHDWidths() {
        for width in [1280, 1920, 2560] {
            let source = MediaSourceInfo(mediaStreams: [MediaStream(index: 0, type: "Video", width: width, height: 720)])
            XCTAssertTrue(makeMovie(mediaSources: [source]).metadataBadges.contains("HD"), "width \(width) should be HD")
        }
    }

    func test_metadataBadges_noResolutionBadgeBelowHD() {
        let source = MediaSourceInfo(mediaStreams: [MediaStream(index: 0, type: "Video", width: 640, height: 480)])
        let badges = makeMovie(mediaSources: [source]).metadataBadges
        XCTAssertFalse(badges.contains("4K"))
        XCTAssertFalse(badges.contains("HD"))
    }

    func test_metadataBadges_dolbyVisionForAnyDOVIVariant() {
        for variant in ["DOVI", "DOVIWithHDR10", "DOVIWithHDR10Plus", "DOVIWithHLG", "DOVIWithSDR"] {
            let source = MediaSourceInfo(mediaStreams: [MediaStream(index: 0, type: "Video", videoRangeType: variant)])
            XCTAssertEqual(makeMovie(mediaSources: [source]).metadataBadges, ["Dolby Vision"], "variant \(variant)")
        }
    }

    func test_metadataBadges_pureHDR10() {
        let source = MediaSourceInfo(mediaStreams: [MediaStream(index: 0, type: "Video", videoRangeType: "HDR10")])
        XCTAssertEqual(makeMovie(mediaSources: [source]).metadataBadges, ["HDR10"])
    }

    func test_metadataBadges_pureHDR10Plus() {
        let source = MediaSourceInfo(mediaStreams: [MediaStream(index: 0, type: "Video", videoRangeType: "HDR10Plus")])
        XCTAssertEqual(makeMovie(mediaSources: [source]).metadataBadges, ["HDR10+"])
    }

    func test_metadataBadges_hlgIsGenericHDRBadge() {
        let source = MediaSourceInfo(mediaStreams: [MediaStream(index: 0, type: "Video", videoRangeType: "HLG")])
        XCTAssertEqual(makeMovie(mediaSources: [source]).metadataBadges, ["HDR"])
    }

    func test_metadataBadges_noBadgeForSDR() {
        let source = MediaSourceInfo(mediaStreams: [MediaStream(index: 0, type: "Video", videoRangeType: "SDR")])
        XCTAssertTrue(makeMovie(mediaSources: [source]).metadataBadges.isEmpty)
    }

    // Dolby Digital family collapses to one badge: Atmos > DD+ > DD.

    func test_metadataBadges_ddWhenOnlyPlainDolbyDigitalPresent() {
        let source = MediaSourceInfo(mediaStreams: [MediaStream(index: 0, type: "Audio", codec: "AC3")])
        XCTAssertEqual(makeMovie(mediaSources: [source]).metadataBadges, ["DD"])
    }

    func test_metadataBadges_ddPlusWinsOverPlainDDWhenBothPresent() {
        let source = MediaSourceInfo(mediaStreams: [
            MediaStream(index: 0, type: "Audio", codec: "ac3"),
            MediaStream(index: 1, type: "Audio", codec: "eac3")
        ])
        XCTAssertEqual(makeMovie(mediaSources: [source]).metadataBadges, ["DD+"])
    }

    func test_metadataBadges_atmosWinsOverDDAndDDPlusWhenAllPresent() {
        let source = MediaSourceInfo(mediaStreams: [
            MediaStream(index: 0, type: "Audio", codec: "ac3"),
            MediaStream(index: 1, type: "Audio", codec: "eac3"),
            MediaStream(index: 2, type: "Audio", audioSpatialFormat: "DolbyAtmos")
        ])
        XCTAssertEqual(makeMovie(mediaSources: [source]).metadataBadges, ["Dolby Atmos"])
    }

    func test_metadataBadges_noAtmosBadgeForOtherSpatialFormats() {
        let source = MediaSourceInfo(mediaStreams: [MediaStream(index: 0, type: "Audio", audioSpatialFormat: "DTSX")])
        XCTAssertFalse(makeMovie(mediaSources: [source]).metadataBadges.contains("Dolby Atmos"))
    }

    // Dolby TrueHD is the exception to that collapsing: always shown
    // alongside whichever Dolby Digital family badge wins.

    func test_metadataBadges_trueHDShownAlongsideAtmosWhenBothOnSameTrack() {
        // A TrueHD track commonly also carries an Atmos layer.
        let source = MediaSourceInfo(mediaStreams: [MediaStream(index: 0, type: "Audio", codec: "truehd", audioSpatialFormat: "DolbyAtmos")])
        XCTAssertEqual(makeMovie(mediaSources: [source]).metadataBadges, ["Dolby Atmos", "Dolby TrueHD"])
    }

    func test_metadataBadges_trueHDShownAlongsideDDPlusWhenNoAtmos() {
        let source = MediaSourceInfo(mediaStreams: [
            MediaStream(index: 0, type: "Audio", codec: "truehd"),
            MediaStream(index: 1, type: "Audio", codec: "eac3")
        ])
        XCTAssertEqual(makeMovie(mediaSources: [source]).metadataBadges, ["DD+", "Dolby TrueHD"])
    }

    // DTS family collapses to one badge the same way: DTS-HD > plain DTS.
    // Jellyfin/ffprobe report every DTS variant as codec "dts"; only the
    // `profile` field ("DTS-HD MA"/"DTS-HD HRA") distinguishes HD from core.

    func test_metadataBadges_plainDTSWhenNoHDProfile() {
        let source = MediaSourceInfo(mediaStreams: [MediaStream(index: 0, type: "Audio", codec: "dts")])
        XCTAssertEqual(makeMovie(mediaSources: [source]).metadataBadges, ["DTS"])
    }

    func test_metadataBadges_dtsHDDetectedViaProfile() {
        for profile in ["DTS-HD MA", "DTS-HD HRA"] {
            let source = MediaSourceInfo(mediaStreams: [MediaStream(index: 0, type: "Audio", codec: "dts", profile: profile)])
            XCTAssertEqual(makeMovie(mediaSources: [source]).metadataBadges, ["DTS-HD"], "profile \(profile)")
        }
    }

    func test_metadataBadges_dtsHDWinsOverPlainDTSWhenBothPresent() {
        let source = MediaSourceInfo(mediaStreams: [
            MediaStream(index: 0, type: "Audio", codec: "dts"),
            MediaStream(index: 1, type: "Audio", codec: "dts", profile: "DTS-HD MA")
        ])
        XCTAssertEqual(makeMovie(mediaSources: [source]).metadataBadges, ["DTS-HD"])
    }

    /// The example from the request this was built against: Atmos, TrueHD,
    /// and DTS-HD can all appear together, with no other Dolby/DTS badges,
    /// even though there are three separate audio tracks contributing.
    func test_metadataBadges_atmosTrueHDAndDTSHDCanAllAppearWithNoOtherAudioBadges() {
        let source = MediaSourceInfo(mediaStreams: [
            MediaStream(index: 0, type: "Audio", codec: "truehd", audioSpatialFormat: "DolbyAtmos"),
            MediaStream(index: 1, type: "Audio", codec: "dts", profile: "DTS-HD MA")
        ])
        XCTAssertEqual(makeMovie(mediaSources: [source]).metadataBadges, ["Dolby Atmos", "Dolby TrueHD", "DTS-HD"])
    }

    func test_metadataBadges_ccWhenANonForcedSubtitleTrackExists() {
        let source = MediaSourceInfo(mediaStreams: [MediaStream(index: 0, type: "Subtitle", isForced: false)])
        XCTAssertEqual(makeMovie(mediaSources: [source]).metadataBadges, ["CC"])
    }

    func test_metadataBadges_noCCWhenAllSubtitlesAreForced() {
        let source = MediaSourceInfo(mediaStreams: [
            MediaStream(index: 0, type: "Subtitle", isForced: true),
            MediaStream(index: 1, type: "Subtitle", isForced: true)
        ])
        XCTAssertFalse(makeMovie(mediaSources: [source]).metadataBadges.contains("CC"))
    }

    func test_metadataBadges_noCCWhenNoSubtitleTracks() {
        XCTAssertFalse(makeMovie(mediaSources: [MediaSourceInfo()]).metadataBadges.contains("CC"))
    }

    func test_metadataBadges_adFromIsHearingImpairedFlag() {
        let source = MediaSourceInfo(mediaStreams: [MediaStream(index: 0, type: "Audio", isHearingImpaired: true)])
        XCTAssertEqual(makeMovie(mediaSources: [source]).metadataBadges, ["AD"])
    }

    func test_metadataBadges_adFromAudioTrackTitleText() {
        for title in ["Audio Description", "English SDH", "For the Hard of Hearing"] {
            let source = MediaSourceInfo(mediaStreams: [MediaStream(index: 0, type: "Audio", title: title)])
            XCTAssertEqual(makeMovie(mediaSources: [source]).metadataBadges, ["AD"], "title \(title)")
        }
    }

    func test_metadataBadges_emptyWhenNoMediaSources() {
        XCTAssertEqual(makeMovie().metadataBadges, [])
    }

    func test_metadataBadges_combinedOrderMatchesResolutionRangeAudioSubtitleAD() {
        let source = MediaSourceInfo(mediaStreams: [
            MediaStream(index: 0, type: "Video", width: 3840, height: 2160, videoRangeType: "DOVI"),
            MediaStream(index: 1, type: "Audio", codec: "eac3", audioSpatialFormat: "DolbyAtmos"),
            MediaStream(index: 2, type: "Audio", isHearingImpaired: true),
            MediaStream(index: 3, type: "Subtitle", isForced: false)
        ])
        XCTAssertEqual(
            makeMovie(mediaSources: [source]).metadataBadges,
            ["4K", "Dolby Vision", "Dolby Atmos", "CC", "AD"]
        )
    }

    // MARK: cast

    func test_cast_actorUsesRoleAsCharacterName() {
        let person = BaseItemPerson(id: "p1", name: "Timothée Chalamet", role: "Paul Atreides", type: "Actor")
        let dto = BaseItemDto(id: "movie-1", name: "Dune", type: .movie, people: [person])
        XCTAssertEqual(MediaItem(dto: dto, images: images).cast, [
            CastMember(id: "p1-0", name: "Timothée Chalamet", role: "Paul Atreides", imageURL: nil)
        ])
    }

    /// The bug this guards against: the same real person can be credited
    /// more than once on the same item (e.g. an actor who also directed),
    /// sharing the same underlying `person.id` across those entries. Using
    /// that id alone for `CastMember.id` gave `CastCrewGridView`'s `ForEach`
    /// duplicate identifiers — SwiftUI's diffing has no reliable way to
    /// tell two same-id cells apart while scrolling, which showed up as
    /// intermittent gaps and repeated cells in the grid.
    func test_cast_idsAreUniquePerCreditEvenWhenTheSamePersonAppearsTwice() {
        let actingCredit = BaseItemPerson(id: "p1", name: "Ben Affleck", role: "Batman", type: "Actor")
        let directingCredit = BaseItemPerson(id: "p1", name: "Ben Affleck", role: nil, type: "Director")
        let dto = BaseItemDto(id: "movie-1", name: "Justice League", type: .movie, people: [actingCredit, directingCredit])
        let ids = MediaItem(dto: dto, images: images).cast.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "duplicate ids: \(ids)")
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

    func test_thumbImageURL_includesTagAndToken() {
        let dto = BaseItemDto(id: "ep-1", name: "Old Cases", type: .episode, imageTags: ["Thumb": "thumb123"])
        let item = MediaItem(dto: dto, images: images)
        let url = item.thumbImageURL
        XCTAssertNotNil(url)
        XCTAssertTrue(url!.absoluteString.contains("Items/ep-1/Images/Thumb"))
        XCTAssertTrue(url!.absoluteString.contains("tag=thumb123"))
    }

    func test_thumbImageURL_nilWhenNoThumbTag() {
        XCTAssertNil(makeMovie().thumbImageURL)
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

    // MARK: usesLandscapeRailTile

    func test_usesLandscapeRailTile_trueForSeriesAndEpisode() {
        XCTAssertTrue(makeSeries().usesLandscapeRailTile)
        XCTAssertTrue(makeEpisode().usesLandscapeRailTile)
    }

    func test_usesLandscapeRailTile_falseForMovie() {
        XCTAssertFalse(makeMovie().usesLandscapeRailTile)
    }

    func test_usesLandscapeRailTile_falseForBoxSet() {
        let dto = BaseItemDto(id: "box-1", name: "Trilogy", type: .boxSet)
        XCTAssertFalse(MediaItem(dto: dto, images: images).usesLandscapeRailTile)
    }

    // MARK: libraryContentItemTypes

    private func makeLibrary(collectionType: String?) -> MediaItem {
        let dto = BaseItemDto(id: "lib-1", name: "Library", type: .collectionFolder, collectionType: collectionType)
        return MediaItem(dto: dto, images: images)
    }

    func test_libraryContentItemTypes_moviesLibrary_restrictsToMovie() {
        XCTAssertEqual(makeLibrary(collectionType: "movies").libraryContentItemTypes, ["Movie"])
    }

    func test_libraryContentItemTypes_showsLibrary_restrictsToSeries() {
        // The whole point: a recursive `/Items?ParentId=` walk under a
        // Shows library returns every Season/Episode too, not just each
        // Series — this is what keeps a tvshows library's grid to just
        // the shows themselves.
        XCTAssertEqual(makeLibrary(collectionType: "tvshows").libraryContentItemTypes, ["Series"])
    }

    func test_libraryContentItemTypes_collectionsLibrary_restrictsToBoxSet() {
        XCTAssertEqual(makeLibrary(collectionType: "boxsets").libraryContentItemTypes, ["BoxSet"])
    }

    func test_libraryContentItemTypes_unrecognizedOrMissingCollectionType_isUnrestricted() {
        XCTAssertEqual(makeLibrary(collectionType: "music").libraryContentItemTypes, [])
        XCTAssertEqual(makeLibrary(collectionType: nil).libraryContentItemTypes, [])
        XCTAssertEqual(makeMovie().libraryContentItemTypes, [], "Not a library at all — collectionType is nil")
    }
}
